using Herb.HerbCore: AbstractRuleNode, AbstractGrammar
using Herb.HerbGrammar: normalize
using Herb.HerbSpecification: AbstractSpecification, Problem
using Herb.HerbSearch: ProgramIterator, TopDownIterator


"""
    $(TYPEDSIGNATURES)

Synthesize a program using the `grammar` that follows the `spec` following the method from 
["Just-in-time learning for bottom-up enumerative synthesis"](https://doi.org/10.1145/3428295).
```
"""
function probe(
        iterator_type::Type{T},
        grammar::AbstractGrammar,
        starting_sym::Symbol,
        problem::Problem;
        max_iterations::Int = typemax(Int),
        probe_cycles::Int = 3,
        max_iteration_time::Int = typemax(Int),
        kwargs...
)::Union{AbstractRuleNode, Nothing} where {T <: ProgramIterator}

    for _ in 1:probe_cycles

        # Gets an iterator with some limit (the low-level budget)
        iterator = iterator_type(grammar, starting_sym; kwargs...)

        # Run a budgeted search
        promising_programs, result_flag = get_promising_programs(
            iterator, problem; max_time = max_iteration_time,
            max_enumerations = max_iterations)

        if result_flag == optimal_program
            return only(promising_programs) # returns the only element
        end

        # Throw an error if no programs were found.
        if length(promising_programs) == 0
            throw(NoProgramFoundError("No promising program found for the given specification. Try exploring more programs."))
        end

        # Update grammar probabilities 
        modify_grammar_probe!(promising_programs, grammar; norm_value=1)
    end

    @warn "No solution found. Within $probe_cycles iterations."
    return nothing
end


function rulenode_log_probability(hole::UniformHole, grammar::AbstractGrammar)
    first_index = findfirst(x -> x == 1, hole.domain)
    return log_probability(grammar, first_rule) + sum((rulenode_log_probability(c, grammar) for c ∈ node.children), init=1)
end

"""
    $(TYPEDSIGNATURES)

Overwrite rulenode_log_probability from HerbGrammar for ::Hole. 
"""
function rulenode_log_probability(hole::Hole, grammar::AbstractGrammar)
    first_index = findfirst(x -> x == 1, hole.domain)
    return log_probability(grammar, first_rule)
end

"""
    $(TYPEDSIGNATURES)

Overwrite AbstractDFS iterator to use probabilities as priority value instead. 
"""
function priority_function(
    ::AbstractDFSIterator, 
    grammar::AbstractGrammar, 
    current_program::AbstractRuleNode, 
    parent_value::Union{Real, Tuple{Vararg{Real}}},
    isrequeued::Bool
)
    return rulenode_log_probability(current_program, grammar);
end


"""
    $(TYPEDSIGNATURES)

Decide whether to keep a program, or discard it, based on the specification.
"""
function decide_probe(
        program::AbstractRuleNode,
        problem::Problem,
        grammar::ContextSensitiveGrammar,
        symboltable::SymbolTable)::Real
    expr = rulenode2expr(program, grammar)
    fitness = evaluate(problem, expr, symboltable, shortcircuit = false)
    return fitness
end

"""
    $(TYPEDSIGNATURES)

Modify the grammar based on the programs kept during the `decide` step.
"""
function modify_grammar_probe!(
        saved_program_fitness::AbstractVector{Tuple{<:AbstractRuleNode, Real}},
        grammar::AbstractGrammar
)::AbstractGrammar 
    orig_probs = exp.(grammar.log_probabilities)
    
    for i in 1:length(grammar.log_probabilities)
        max_fitness = 0

        # Find maximum fitness for programs with that rule among saved programs
        for (program, fitness) in saved_program_fitness
            if !isempty(rulesoftype(program, i)) && fitness > max_fitness
                max_fitness = fitness                
            end
        end

        # Update the probability according to the Probe formula
        orig_probs[i] = log_probability(grammar, i)^(1-max_fitness)
    end
    # Normalize probabilities after the update
    normalize!(grammar)

    return grammar
end

function 


"""
    $(TYPEDSIGNATURES)

Iterates over the solutions to find partial or full solutions.
Takes an iterator to enumerate programs. Quits when `max_time` or `max_enumerations` is reached.
If the program solves the problem, it is returned with the `optimal_program` flag.
If a program solves some of the problem (e.g. some but not all examples) it is added to the list of `promising_programs`.
The set of promising programs is returned eventually.
"""
function get_promising_programs(
        iterator::ProgramIterator,
        problem::Problem;
        max_time = typemax(Int),
        max_enumerations = typemax(Int),
        mod::Module = Main
)::Tuple{Set{Tuple{AbstractRuleNode, Real}}, SynthResult}
    start_time = time()
    grammar = get_grammar(iterator.solver)
    symboltable::SymbolTable = grammar2symboltable(grammar, mod)

    promising_programs = Set{Tuple{AbstractRuleNode, Real}}()

    for (i, candidate_program) in enumerate(iterator)
        fitness = decide_frangel(candidate_program, problem, grammar, symboltable)

        if fitness == 1
            push!(promising_programs, (freeze_state(candidate_program), fitness))
            return (promising_programs, optimal_program)
        elseif fitness > 0
            push!(promising_programs, (freeze_state(candidate_program), fitness)
        end

        # Check stopping criteria
        if i > max_enumerations || time() - start_time > max_time
            break
        end
    end

    return (promising_programs, suboptimal_program)
end