module ConflictAnalysis

using DocStringExtensions
using ConflictAnalysis
using Herb.HerbCore: AbstractRuleNode, AbstractGrammar
using Herb.HerbSpecification: IOExample, Problem
using Herb.HerbSearch: ProgramIterator, add_constraints!
using Herb.HerbConstraints: AbstractGrammarConstraint, get_grammar, freeze_state
using Herb.HerbInterpret: SymbolTable, execute_on_input
using Herb.HerbGrammar: grammar2symboltable, rulenode2expr, addconstraint!

function run_problem(
    problem::Problem,
    iterator::ProgramIterator;
    max_time = typemax(Int),
    max_enumerations = typemax(Int),
    mod::Module = Main,
    conflict_analysis::Bool = true,
    techniques::Vector{Symbol} = [:ERA, :MUC, :SeAn]

)::Tuple{Union{AbstractRuleNode, Nothing}, Int64, Int64, Float64}
    start_time   = time()
    solver       = iterator.solver
    grammar      = get_grammar(solver)
    symboltable  = grammar2symboltable(grammar, mod)
    counter      = 0
    cons_counter = 0

    techs = build_techniques(techniques)
    try
        for (i, candidate_program) ∈ enumerate(iterator)
            expr = rulenode2expr(candidate_program, grammar)
            output, result, counter_example = evaluate(problem, expr, symboltable)
            counter += 1

            if result == success
                return (freeze_state(candidate_program), counter, cons_counter, round(time() - start_time, digits=2))
            else
                if conflict_analysis
                    ctx = ConflictContext(grammar, symboltable, candidate_program, output, counter_example)
                    constraints, grammar_constraints = run_conflict_pipeline(techs, ctx)

                    for c in grammar_constraints
                        addconstraint!(grammar, c.cons)
                    end
                    if !isempty(constraints)
                        add_constraints!(iterator, AbstractGrammarConstraint[c.cons for c in constraints])
                    end

                    cons_counter += length(constraints) + length(grammar_constraints)
                end
            end

            if i > max_enumerations || time() - start_time > max_time
                println("Stopping criteria met")
                break
            end
        end
    catch e
        println(output, score, counter_example)
    end

    # Clean up
    for t in techs
        try
            close_solver(t)
        catch _
            # ignore if technique has no resources
        end
    end

    println("Total number of constraints added: $cons_counter")
    return (nothing, counter, cons_counter, round(time() - start_time, digits=2))
end

@enum EvalResult success=1 failed=2 crashed=3
"""
    evaluate(problem::Problem{Vector{IOExample}}, expr::Any, symboltable::SymbolTable)

Evaluate the expression on the examples.

Returns a score in the interval [0, 1]
"""
function evaluate(
    problem::Problem{<:AbstractVector{<:IOExample}},
    expr::Any,
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

export
    run_problem

end