using Herb.HerbCore: AbstractRuleNode, AbstractGrammar
using Herb.HerbSpecification: AbstractSpecification, Problem
using Herb.HerbSearch: ProgramIterator

"""
    $(TYPEDSIGNATURES)

Decide whether to keep a program, or discard it, based on the specification.
"""
function decide_frangel(
        program::AbstractRuleNode,
        spec::AbstractSpecification
)::Bool end

"""
    $(TYPEDSIGNATURES)

Modify the grammar based on the programs kept during the `decide` step.
"""
function modify_grammar_frangel(
        saved_programs::AbstractVector{<:AbstractRuleNode},
        grammar::AbstractGrammar
)::AbstractGrammar end

"""
    $(TYPEDSIGNATURES)

Synthesize a program using the `grammar` that follows the `spec` following the method from 
["DreamCoder: bootstrapping inductive program synthesis with wake-sleep library learning."](https://doi.org/10.1145/3453483.3454080).
```
"""
function dreamcoder(
        iterator::ProgramIterator,
        grammar::AbstractGrammar,
        spec::Problem,
        budget::Int,
        max_total_iterations::Int;
        kwargs...
)::AbstractRuleNode

    # - Run a budgeted search
    #   - Gets an iterator with some limit (the low-level budget)
    #   - !!! This iterator will have some neural element that is not
    #   yet included in this skeleton. This should be addressed before
    #   we start implementing.
    # - Collect (partial) successes
    #   - Function to define success, which is just % of examples solved by default
    #   - Function takes any kind of specification
    #   - Boolean output: should the program be saved or not?
    # - Modify the grammar
    #   - Function to modify the grammar based on the successes
    #   - Takes the successes (saved programs)
    #   - Modify the grammar: in place or return a new one, TBD
    # - Rinse and repeat
    #   - Function defining high-level budget
    #   - For now, just a parameter defining the number of overall runs of budgeted search

end