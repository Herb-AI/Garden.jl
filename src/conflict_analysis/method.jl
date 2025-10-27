module ConflictAnalysis

using DocStringExtensions
using ConflictAnalysis
using MLStyle
using Herb.HerbCore: AbstractRuleNode, AbstractGrammar
using Herb.HerbSpecification: IOExample, Problem
using Herb.HerbConstraints: AbstractGrammarConstraint, get_grammar, freeze_state
using Herb.HerbInterpret: SymbolTable, execute_on_input
using HerbSearch: ProgramIterator, add_constraints!
using HerbGrammar: grammar2symboltable, rulenode2expr, addconstraint!, ContextSensitiveGrammar

include("overhead.jl")

function run_problem(
    problem::Problem,
    iterator::ProgramIterator,
    interpret::Union{Function, Nothing} = nothing;
    max_time = typemax(Int),
    max_enumerations = typemax(Int),
    mod::Module = Main,
    conflict_analysis::Bool = true,
    techniques::Vector{Symbol} = [:ERA, :MUC, :SeAn]

)::Tuple{Union{AbstractRuleNode, Nothing}, Int64, Int64, OverheadMetrics}
    start_time   = time_ns()
    solver       = iterator.solver
    grammar      = get_grammar(solver)
    grammar_tags = get_relevant_tags(grammar)
    symboltable  = grammar2symboltable(grammar, mod)
    counter      = 0
    cons_counter = 0

    metrics = OverheadMetrics();
    techs = build_techniques(techniques)

    start = @measure! (metrics, :propagation_ns) iterate(iterator)
    if isnothing(start)
        metrics.total_ns = (time_ns() - start_time)
        return (nothing, counter, cons_counter, metrics)
    end

    candidate_program, state = start
    while true
        expr = rulenode2expr(candidate_program, grammar)
        output, result, counter_example = isnothing(interpret) ? 
            evaluate(expr, problem, symboltable) : 
            evaluate(candidate_program, problem, grammar_tags, interpret)
        counter += 1

        if result == success
            metrics.total_ns = (time_ns() - start_time)
            return (freeze_state(candidate_program), counter, cons_counter, metrics)
        else
            if conflict_analysis
                ctx = ConflictContext(grammar, symboltable, candidate_program, output, counter_example)
                constraints, grammar_constraints = @measure! (metrics, :analysis_ns) run_conflict_pipeline(techs, ctx)
                
                for c in grammar_constraints
                    addconstraint!(grammar, c.cons)
                end
                if !isempty(constraints)
                    add_constraints!(iterator, AbstractGrammarConstraint[c.cons for c in constraints])
                end

                cons_counter += length(constraints) + length(grammar_constraints)
            end
        end

        if counter > max_enumerations || float(time_ns() - start_time) / 1e9 > max_time
            println("Stopping criteria met")
            break
        end

        next = @measure! (metrics, :propagation_ns) iterate(iterator, state)
        if isnothing(next)
            break
        end
        candidate_program, state = next
    end

    # Clean up
    for t in techs
        try
            close_solver(t)
        catch _
            # ignore if technique has no resources
        end
    end

    metrics.total_ns = (time_ns() - start_time)
    return (nothing, counter, cons_counter, metrics)
end

"""
Gets relevant symbol to easily match grammar rules to operations in `interpret` function
"""
function get_relevant_tags(grammar::ContextSensitiveGrammar)
    tags = Dict{Int,Any}()
    for (ind, r) in pairs(grammar.rules)
        tags[ind] = if typeof(r) != Expr
            r
        else
            @match r.head begin
                :block => :OpSeq
                :call => r.args[1]
                :if => :IF
            end
        end
    end
    return tags
end

"""
    execute_on_input(tab::SymbolTable, expr::Any, input::Dict{Symbol, T}, interpret::Function)::Any where T

Custom execute_on_input function that uses a given interpret function.
"""
function ConflictAnalysis.execute_on_input(program::AbstractRuleNode, grammar_tags::Dict{Int, Any}, input::Dict{Symbol, T}, interpret::Function)::Any where T
    return interpret(program, grammar_tags, input)
end

@enum EvalResult success=1 failed=2 crashed=3
"""
    evaluate(
        expr::Any,
        problem::Problem{<:AbstractVector{<:IOExample}},
        symboltable::SymbolTable
    )::Tuple{Union{Any, Nothing}, EvalResult, Union{<:IOExample, Nothing}}

Evaluate the expression on the examples using the given symboltable.
"""
function evaluate(
    expr::Any,
    problem::Problem{<:AbstractVector{<:IOExample}},
    symboltable::SymbolTable
)::Tuple{Union{Any, Nothing}, EvalResult, Union{<:IOExample, Nothing}}
    output = nothing

    for example ∈ problem.spec
        try
            output = execute_on_input(symboltable, expr, example.in)
            if (output != example.out)
                return (output, failed, example)
            end
        catch e
            return (nothing, crashed, example)
        end
    end

    return (output, success, nothing)
end

"""
    evaluate(
        program::AbstractRuleNode,
        problem::Problem{<:AbstractVector{<:IOExample}},
        grammar_tags::Dict{Int, Any},
        interpret::Union{Function, Nothing} = nothing
    )::Tuple{Union{Any, Nothing}, EvalResult, Union{<:IOExample, Nothing}}

Evaluate the program on the examples using a custom interpret function if provided.
"""
function evaluate(
    program::AbstractRuleNode,
    problem::Problem{<:AbstractVector{<:IOExample}},
    grammar_tags::Dict{Int, Any},
    interpret::Union{Function, Nothing} = nothing
)::Tuple{Union{Any, Nothing}, EvalResult, Union{<:IOExample, Nothing}}
    output = nothing

    for example ∈ problem.spec
        try
            output = execute_on_input(program, grammar_tags, example.in, interpret)
            if (output != example.out)
                return (output, failed, example)
            end
        catch e
            return (nothing, crashed, example)
        end
    end

    return (output, success, nothing)
end

export
    run_problem
end
