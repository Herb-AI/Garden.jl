using Herb.HerbCore: AbstractRuleNode, AbstractGrammar
using Herb.HerbSpecification: AbstractSpecification, Problem
using Herb.HerbSearch: ProgramIterator, evaluate
using Herb.HerbInterpret: SymbolTable
using Herb.HerbConstraints: get_grammar, freeze_state
using Herb.HerbGrammar: rulenode2expr, isterminal, iscomplete


"""
    $(TYPEDSIGNATURES)

Synthesize a program using the `grammar` that follows the `spec` following the method from 
["FrAngel: component-based synthesis with control structures"](https://doi.org/10.1145/3290386).
```
"""
function frangel(
        iterator_type::Type{T},
        grammar::AbstractGrammar,
        starting_sym::Symbol,
        problem::Problem,
        budget::Int,
        max_total_iterations::Int;
        max_iteration_time::Int=typemax(Int),
        kwargs...
)::AbstractRuleNode where T<:ProgramIterator
    # FrAngel config arguments
    num_frangel_steps = 3

    for frangel_iteration in 1:num_frangel_steps
        # Gets an iterator with some limit (the low-level budget)
        iterator = construct_iterator(iterator_type, grammar, starting_sym)

        # Run a budgeted search
        promising_programs = get_promising_programs(iterator, problem; max_time=max_iteration_time, max_enumerations=max_total_iterations)
        println(promising_programs)
        println(typeof(promising_programs))

        if length(promising_programs) == 0
            error("Not implemented yet.")
        end

        # Extract fragments
        fragments = mine_fragments(grammar, promising_programs)
        println("Fragments: $fragments")

        # Modify grammar
        add_fragments_to_grammar!(fragments, grammar)
    end

    #   - This is a normal iterator
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


"""
    $(TYPEDSIGNATURES)

Decide whether to keep a program, or discard it, based on the specification.
"""
function decide_frangel(
        program::AbstractRuleNode,
        problem::Problem,
        grammar::ContextSensitiveGrammar,
        symboltable::SymbolTable
)::Bool 
    expr = rulenode2expr(program, grammar)
    score = evaluate(problem, expr, symboltable, shortcircuit=false)
    return score > 0
end

"""
    $(TYPEDSIGNATURES)

Modify the grammar based on the programs kept during the `decide` step.
"""
function modify_grammar_frangel(
        saved_programs::AbstractVector{<:AbstractRuleNode},
        grammar::AbstractGrammar
)::AbstractGrammar 

end


"""
    $(TYPEDSIGNATURES)

"""
function get_promising_programs(
    iterator::ProgramIterator,
    problem::Problem;
    max_time = typemax(Int),
    max_enumerations = typemax(Int),
    mod::Module=Main
)::Set{AbstractRuleNode}
    start_time = time()
    grammar = get_grammar(iterator.solver)
    symboltable :: SymbolTable = SymbolTable(grammar, mod)

    promising_programs = Set{AbstractRuleNode}()

    for (i, candidate_program) ∈ enumerate(iterator)
        # Create expression from rulenode representation of AST

        # Evaluate the expression
        if decide_frangel(candidate_program, problem, grammar, symboltable)
            push!(promising_programs, freeze_state(candidate_program))
        end

        # Check stopping criteria
        if i > max_enumerations || time() - start_time > max_time
            break;
        end
    end

    return promising_programs
end

"""
    $(TYPEDSIGNATURES)

Finds all the fragments from the provided `program`. The result is a set of the distinct fragments, generated recursively by going over all children.
A fragment is any complete subprogram of the original program.

# Arguments
- `grammar`: The grammar rules of the program.
- `program`: The program to mine fragments for.

# Returns
All the found fragments in the provided program.

"""
function mine_fragments(grammar::AbstractGrammar, program::AbstractRuleNode)::Set{AbstractRuleNode}
    fragments = Set{AbstractRuleNode}()
    prinltn("program: $program")
    prinltn("program: $(isterminal(program))")
    prinltn("program: $(iscomplete(program))")
    # Push terminals as they are
    if !isterminal(grammar, program)
        # Only complete programs count are considered
        if iscomplete(grammar, program)
            push!(fragments, program)
        end
        for child in program.children
            fragments = union(fragments, mine_fragments(grammar, child))
        end
    end
    fragments
end

"""
    $(TYPEDSIGNATURES)

Finds all the fragments from the provided `programs` set. The result is a set of the distinct fragments found within all programs.
A fragment is any complete subprogram of the original program.

# Arguments
- `grammar`: The grammar rules of the program.
- `programs`: A set of programs to mine fragments for.

# Returns
All the found fragments in the provided programs.

"""
function mine_fragments(grammar::AbstractGrammar, programs::Set{AbstractRuleNode})::Set{AbstractRuleNode}
    fragments = reduce(union, mine_fragments(grammar, p) for p in programs)
    for program in programs
        delete!(fragments, program)
    end
    fragments
end

"""
    $(TYPEDSIGNATURES)


"""
function add_fragments_to_grammar!(fragments::Set{AbstractRuleNode}, grammar::AbstractGrammar)
    for f in fragments
        println("fragment: $f")
        error()

        ind = get_rule(f)
        type = grammar.types[ind]
        expr = rulenode2expr(f, grammar)
        add_rule!(grammar, Meta.parse("$type = $expr"))
    end
end