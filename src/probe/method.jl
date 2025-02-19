using Herb.HerbCore: AbstractRuleNode, AbstractGrammar
using Herb.HerbGrammar: normalize!, init_probabilities!
using Herb.HerbSpecification: AbstractSpecification, Problem
using Herb.HerbConstraints: freeze_state
using Herb.HerbSearch: @programiterator, evaluate


"""
    $(TYPEDSIGNATURES)

Synthesize a program using the `grammar` that follows the `spec` following the method from 
["Just-in-time learning for bottom-up enumerative synthesis"](https://doi.org/10.1145/3428295).
```
"""
function probe(
        grammar::AbstractGrammar,
        starting_sym::Symbol,
        problem::Problem;
        max_iterations::Int = typemax(Int),
        probe_cycles::Int = 3,
        max_iteration_time::Int = typemax(Int),
        kwargs...
)::Union{AbstractRuleNode, Nothing}# where {T <: ProgramIterator}
    if isnothing(grammar.log_probabilities)
        init_probabilities!(grammar)
    end

    for _ in 1:probe_cycles
        # Gets an iterator with some limit (the low-level budget)
        # iterator = iterator_type(grammar, starting_sym; kwargs...)
        iterator = ProbabilisticTopDownIterator(grammar, starting_sym; kwargs...)

        # Run a budgeted search
        promising_programs, result_flag = get_promising_programs_with_fitness(
            iterator, problem; max_time = max_iteration_time,
            max_enumerations = max_iterations)

        if result_flag == optimal_program
            program, score = only(promising_programs) # returns the only element
            return program
        end

        # Throw an error if no programs were found.
        if length(promising_programs) == 0
            throw(NoProgramFoundError("No promising program found for the given specification. Try exploring more programs."))
        end

        # Update grammar probabilities 
        modify_grammar_probe!(promising_programs, grammar)
    end

    @warn "No solution found within $probe_cycles Probe iterations."
    return nothing
end


Base.@doc """
    @programiterator ProbabilisticTopDownIterator() <: TopDownIterator

A top-down iterator that enumerates solutions by decreasing probability.
""" ProbabilisticTopDownIterator
@programiterator ProbabilisticTopDownIterator() <:TopDownIterator

"""
    derivation_heuristic(iter::ProbabilisticTopDownIterator, domain::Vector{Int})

Define `derivation_heuristic` for the iterator type `ProbabilisticTopDownIterator`. 
Decides for a domain in which order they should be enumerated. This will invert the enumeration order if probabilities are equal.
"""
function derivation_heuristic(iter::ProbabilisticTopDownIterator, domain::Vector{Int})
    log_probs = get_grammar(iter).log_probabilities
    return sort(domain, by=i->log_probs[i], rev=true) # have highest log_probability first
end

"""
    $(TYPEDSIGNATURES)

Rewrite the priority function of the `ProbabilisticTopDownIterator``. The priority value of a tree is then the max_rulenode_log_probability within the represented uniform tree.
The value is negated as lower priority values are popped earlier.
"""
function priority_function(
    ::ProbabilisticTopDownIterator, 
    grammar::AbstractGrammar, 
    current_program::AbstractRuleNode, 
    parent_value::Union{Real, Tuple{Vararg{Real}}},
    isrequeued::Bool
)
    #@TODO Add requeueing and calculate values from previous values
    return -max_rulenode_log_probability(current_program, grammar) 
end

"""
    max_rulenode_log_probability(rulenode::AbstractRuleNode, grammar::AbstractGrammar)

Calculates the highest possible probability within an `AbstractRuleNode`. 
That is, for each node and its domain, get the highest probability and multiply it with the probabilities of its children, if present. 
As we are operating with log probabilities, we sum the logarithms.
"""
max_rulenode_log_probability(rulenode::AbstractRuleNode, grammar::AbstractGrammar) = rulenode_log_probability(rulenode, grammar)
function max_rulenode_log_probability(hole::UniformHole, grammar::AbstractGrammar)
    max_index = argmax(i -> grammar.log_probabilities[i], findall(hole.domain))
    return log_probability(grammar, min_index) + sum((max_rulenode_log_probability(c, grammar) for c ∈ node.children), init=1)
end

function max_rulenode_log_probability(hole::Hole, grammar::AbstractGrammar)
    max_index = argmax(i -> grammar.log_probabilities[i], findall(hole.domain))
    return log_probability(grammar, max_index)
end


"""
    $(TYPEDSIGNATURES)

Decide whether to keep a program, or discard it, based on the specification. 
Returns the portion of solved examples.
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
Takes a set of programs and their fitnesses, which describe how useful the respective program is.
Updates a rules probability based on the highest program fitness the rule occurred in. 
The update function is taken from the Probe paper. Instead of introducing a normalization value, we just call `normalize!` instead.
"""
function modify_grammar_probe!(
        saved_program_fitness::Set{Tuple{<:AbstractRuleNode, Real}},
        grammar::AbstractGrammar
)::AbstractGrammar 
    orig_probs = exp.(grammar.log_probabilities)
    
    for i in 1:length(grammar.log_probabilities)
        max_fitness = 0

        # Find maximum fitness for programs with that rule among saved programs
        for (program, fitness) in saved_program_fitness
            if !isempty(rulesoftype(program, Set(i))) && fitness > max_fitness
                max_fitness = fitness                
            end
        end

        # Update the probability according to Probe's formula
        prob = log_probability(grammar, i)
        orig_probs[i] = log(exp(prob)^(1-max_fitness))
    end
    # Normalize probabilities after the update
    normalize!(grammar)

    return grammar
end


"""
    $(TYPEDSIGNATURES)

Iterates over the solutions to find partial or full solutions.
Takes an iterator to enumerate programs. Quits when `max_time` or `max_enumerations` is reached.
If the program solves the problem, it is returned with the `optimal_program` flag.
If a program solves some of the problem (e.g. some but not all examples) it is added to the list of `promising_programs`.
The set of promising programs is returned eventually.
"""
function get_promising_programs_with_fitness(
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
        fitness = decide_probe(candidate_program, problem, grammar, symboltable)

        if fitness == 1
            push!(promising_programs, (freeze_state(candidate_program), fitness))
            return (promising_programs, optimal_program)
        elseif fitness > 0
            push!(promising_programs, (freeze_state(candidate_program), fitness))
        end

        # Check stopping criteria
        if i > max_enumerations || time() - start_time > max_time
            break
        end
    end

    return (promising_programs, suboptimal_program)
end