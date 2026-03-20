module FrAngel

using DocStringExtensions
using Herb.HerbCore: AbstractRuleNode, AbstractGrammar, get_rule, isfilled, depth
using Herb.HerbSpecification: AbstractSpecification, Problem
using Herb.HerbSearch: ProgramIterator, evaluate
using Herb.HerbConstraints: get_grammar, freeze_state
using Herb.HerbGrammar: ContextSensitiveGrammar, grammar2symboltable, rulenode2expr, isterminal, iscomplete, add_rule!
using Herb.HerbInterpret: make_interpreter

@enum SynthResult optimal_program=1 suboptimal_program=2

struct NoProgramFoundError <: Exception
    message::String
end

"""
    $(TYPEDSIGNATURES)

Synthesize a program from `grammar` for `problem` using the FrAngel strategy
([Shi, Bieber, and Bodík, PLDI 2019](https://doi.org/10.1145/3290386)).

!!! note

    This implementation only includes **fragment mining**.
    It does **not** implement FrAngel's angelic conditions.

In each cycle, FrAngel runs these steps:

1. enumerating candidate programs,
2. keeping promising partial solutions,
3. mining fragments from those programs, and
4. extending the grammar with the selected fragments.

# Keyword Arguments
- `interpret_builder=HerbInterpret.make_interpreter`: function used to build an interpreter for the current grammar. Typical choices are `HerbInterpret.make_interpreter` and `HerbInterpret.make_stateful_interpreter`.
- `input_symbols::Union{Nothing,AbstractVector{Symbol}}=nothing`: optional input variable names passed to the interpreter builder. If omitted, Herb uses any symbol `_arg_X` as input.
- `interpret_target_module::Module=@__MODULE__`: module into which the interpreter is generated.
- `interpret_cache_module::Module=HerbInterpret`: module used for interpreter caching.
- `max_iterations::Int=typemax(Int)`: maximum number of enumerated programs per round.
- `frangel_iterations::Int=3`: maximum number of fragment-mining rounds.
- `max_iteration_time::Int=typemax(Int)`: time budget in seconds per round.
- `eq::Function=_outputs_match`: predicate used to compare outputs.
- `allow_errors::Bool=true`: if `true`, interpreter errors are treated as failed examples.
- `kwargs...`: forwarded to `iterator_type`; can include `max_size`, `max_depth` and others.

# Customization
To customize behaviour, overwrite `select_fragments`, which defaults to `select_smallest_fragments`.

# Returns
Returns the first program that satisfies all examples, or `nothing` if no exact solution is found within the given budgets.
"""
function frangel(
    iterator_type::Type{T},
    grammar::AbstractGrammar,
    starting_sym::Symbol,
    problem::Problem;
    interpret_builder::F = make_interpreter,
    input_symbols::Union{Nothing,AbstractVector{Symbol}} = nothing,
    interpret_target_module::Module = @__MODULE__,
    interpret_cache_module::Module = @__MODULE__,
    max_iterations::Int = typemax(Int),
    frangel_iterations::Int = 3,
    max_iteration_time::Int = typemax(Int),
    eq::Function = _outputs_match,
    allow_errors::Bool = true,
    kwargs...,
)::Union{AbstractRuleNode, Nothing} where {T <: ProgramIterator, F}
    interp = interpret_builder(
        grammar;
        input_symbols = input_symbols,
        target_module = interpret_target_module,
        cache_module = interpret_cache_module,
    )

    for _ in 1:frangel_iterations
        # Because the generated interpreter depends on the current grammar, it is rebuilt after each grammar update.
        
        iterator = iterator_type(grammar, starting_sym; kwargs...)

        promising_programs, result_flag = get_promising_programs(
            iterator,
            problem,
            interp;
            max_time = max_iteration_time,
            max_enumerations = max_iterations,
            eq = eq,
            allow_errors = allow_errors,
        )

        if result_flag == optimal_program
            return only(promising_programs)
        end

        if isempty(promising_programs)
            @warn "No promising program found for the given specification. Try exploring more programs."
            return nothing
        end

        fragments = mine_fragments(grammar, promising_programs)
        selected_fragments = select_fragments(fragments)
        modify_grammar_frangel!(selected_fragments, grammar)
    end

    @warn "No solution found within $frangel_iterations FrAngel iterations."
    return nothing
end

_outputs_match(x, y) = (x == y)

"""
    $(TYPEDSIGNATURES)

Evaluate a candidate program against `problem`.

Returns the fraction of examples solved. A score of `1.0` means the program
satisfies all examples.
"""
function decide_frangel(
    program::AbstractRuleNode,
    problem::Problem,
    interpret::F;
    eq::Function = _outputs_match,
    allow_errors::Bool = true,
) where {F}
    solved = 0

    for ex in problem.spec
        ok = false

        if allow_errors
            try
                y = interpret(program, ex.in)
                ok = eq(y, ex.out)
            catch
                ok = false
            end
        else
            y = interpret(program, ex.in)
            ok = eq(y, ex.out)
        end

        solved += ok ? 1 : 0
    end

    return solved / length(problem.spec)
end

"""
    $(TYPEDSIGNATURES)

Extend `grammar` with mined fragments.

For each fragment type `T`, this adds an auxiliary nonterminal `Fragment_T`
(if it does not already exist) and then adds the fragment expression as a rule
under that nonterminal.
"""
function modify_grammar_frangel!(
    fragments::AbstractVector{<:AbstractRuleNode},
    grammar::AbstractGrammar;
    max_fragment_rules::Int = typemax(Int),
)
    for f in fragments
        ind = get_rule(f)
        type = grammar.types[ind]
        frag_type = Symbol("Fragment_", type)

        # Introduce the auxiliary fragment nonterminal once per type.
        if !haskey(grammar.bytype, frag_type)
            add_rule!(grammar, Meta.parse("$type = $frag_type"))
        end

        expr = rulenode2expr(f, grammar)
        add_rule!(grammar, Meta.parse("$frag_type = $expr"))
    end

    return grammar
end

"""
    $(TYPEDSIGNATURES)

Selects the smallest (fewest number of nodes) fragments from the set of mined fragments. 
`num_programs` determines how many programs should be selected.
"""
function select_smallest_fragments(
        fragments::Set{AbstractRuleNode};
        num_programs::Int = 3
)::AbstractVector{<:AbstractRuleNode}
    sorted_nodes = sort(collect(fragments), by = x -> length(x))
    return sorted_nodes[1:min(num_programs, length(sorted_nodes))]
end

"""
    $(TYPEDSIGNATURES)

Selects the shallowest (smallest depth) fragments from the set of mined fragments. 
`num_programs` determines how many programs should be selected.
"""
function select_shallowest_fragments(
        fragments::Set{AbstractRuleNode};
        num_programs::Int = 3
)::AbstractVector{<:AbstractRuleNode}
    sorted_nodes = sort(collect(fragments), by = x -> depth(x))

    # Select the top 3 elements
    return sorted_nodes[1:min(num_programs, length(sorted_nodes))]
end

select_fragments(fragments::Set{AbstractRuleNode}) = select_smallest_fragments(fragments; num_programs = 3)

"""
    $(TYPEDSIGNATURES)

Iterate over candidate programs and collect partial or full solutions.

Stops when `max_time` or `max_enumerations` is reached. Programs that solve at least one example are kept as promising programs.
If a program solves the problem, it is returned with the `optimal_program` flag.
"""
function get_promising_programs(
    iterator::ProgramIterator,
    problem::Problem,
    interpret::F;
    max_time = typemax(Int),
    max_enumerations = typemax(Int),
    eq::Function = _outputs_match,
    allow_errors::Bool = true,
)::Tuple{Set{AbstractRuleNode}, SynthResult} where {F}
    start_time = time()
    promising_programs = Set{AbstractRuleNode}()

    for (i, candidate_program) in enumerate(iterator)
        score = decide_frangel(
            candidate_program,
            problem,
            interpret;
            eq = eq,
            allow_errors = allow_errors,
        )

        if score == 1
            empty!(promising_programs)
            push!(promising_programs, freeze_state(candidate_program))
            return (promising_programs, optimal_program)
        elseif score > 0
            push!(promising_programs, freeze_state(candidate_program))
        end

        if i >= max_enumerations || (time() - start_time) > max_time
            break
        end
    end

    return (promising_programs, suboptimal_program)
end


"""
    $(TYPEDSIGNATURES)

Finds all the fragments from the `program` defined over the `grammar`.

The result is a set of the distinct program fragments, generated recursively by iterating over all children. A fragment is any complete subprogram of the original program.

"""
function mine_fragments(
        grammar::AbstractGrammar, program::AbstractRuleNode)::Set{AbstractRuleNode}
    fragments = Set{AbstractRuleNode}()
    # Push terminals as they are
    if isfilled(program) && !isterminal(grammar, program)
        # Only complete programs count are considered
        if iscomplete(grammar, program)
            push!(fragments, program)
        end
        for child in program.children
            fragments = union(fragments, mine_fragments(grammar, child))
        end
    end

    return fragments
end

"""
    $(TYPEDSIGNATURES)

Finds fragments (subprograms) of each program in `programs`.
"""
function mine_fragments(
        grammar::AbstractGrammar, programs::Set{<:AbstractRuleNode})::Set{AbstractRuleNode}
    fragments = reduce(union, mine_fragments(grammar, p) for p in programs)
    fragments = setdiff(fragments, programs) # Don't include the programs themselves in the set of fragments

    return fragments
end

end
