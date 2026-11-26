module LLMBaseline

import Downloads
import JSON
import DocStringExtensions: TYPEDSIGNATURES
import Herb: AbstractGrammar, AbstractRuleNode, RuleNode, Problem, IOExample, nonterminals

# Each file depends only on the files included before it.
include("types.jl")     # shared types and interfaces
include("syntax.jl")    # expression helpers and grammar access
include("backends.jl")  # language models
include("prompts.jl")   # what the model sees
include("parsing.jl")   # from the model's answer to a RuleNode

"""
    $(TYPEDSIGNATURES)

Synthesize a program for `problem` in `grammar`, starting from `starting_sym`, by
prompting a language model.

The model sees the grammar and the examples (by default nothing else, see
`DEFAULT_PROMPT`) and answers with a program in the grammar's concrete syntax.
The answer is parsed back into a derivation of the grammar, so a returned program
is always derivable from `starting_sym`.

`num_samples` independent conversations are tried. Within each, a failed answer
is followed by a feedback message (the parse error, or the failing examples with
the program's outputs) and another try, up to `max_repairs` times.

With an `interpret` function, the first program that solves all examples is
returned, and otherwise the program with the highest fitness. Without one, the
first answer that parses into the grammar is returned, unchecked.

# Keyword arguments
- `model = OllamaModel(DEFAULT_OLLAMA_MODEL)`: the language model; see
  `OllamaModel` and `RECOMMENDED_MODELS`.
- `prompt = DEFAULT_PROMPT`: the prompting strategy; see `PromptTemplate`.
- `interpret = nothing`: `interpret(program, input)` returning the program's
  output for an example's input `Dict`, the same convention as Probe.
  Exceptions count as a failed example.
- `num_samples = 1`: independent samples (set a non-zero temperature).
- `max_repairs = 0`: feedback rounds per sample.
- `eq = (==)`: `eq(output, expected)` compares outputs.
- `seed = nothing`: base seed; sample `i` uses `seed + i - 1`.

# Returns
`(program, attempts)`: a `RuleNode` or `nothing`, and every [`Attempt`](@ref)
made. Run with `JULIA_DEBUG=Garden` to log each attempt.
"""
function llm_synth(
        grammar::AbstractGrammar,
        starting_sym::Symbol,
        problem::Problem{<:AbstractVector{<:IOExample}};
        model::AbstractLanguageModel = OllamaModel(DEFAULT_OLLAMA_MODEL),
        prompt::AbstractPrompt = DEFAULT_PROMPT,
        interpret = nothing,
        num_samples::Int = 1,
        max_repairs::Int = 0,
        eq = (==),
        seed::Union{Nothing, Int} = nothing
    )
    starting_sym in nonterminals(grammar) ||
        throw(ArgumentError("starting symbol `$starting_sym` is not a nonterminal of the grammar"))
    num_samples >= 1 || throw(ArgumentError("num_samples must be at least 1"))
    max_repairs >= 0 || throw(ArgumentError("max_repairs must be non-negative"))

    setup = _Setup(grammar, starting_sym, problem.spec, interpret, eq)
    attempts = Attempt[]
    for sample in 1:num_samples
        sample_seed = isnothing(seed) ? nothing : seed + sample - 1
        solution = _run_sample!(attempts, setup, model, prompt, sample, max_repairs, sample_seed)
        isnothing(solution) || return solution, attempts
    end
    return _best_program(attempts), attempts
end

# What stays fixed during one call of `llm_synth`.
struct _Setup{G <: AbstractGrammar, E <: AbstractVector{<:IOExample}, I, Q}
    grammar::G
    start::Symbol
    examples::E
    interpret::I  # `nothing` or `interpret(program, input)`
    eq::Q
end

# One conversation: ask, judge and give feedback, up to `max_repairs` times.
# Appends every attempt to `attempts`; returns the solution, or `nothing`.
function _run_sample!(attempts, setup::_Setup, model, prompt, sample, max_repairs, seed)
    messages = initial_messages(prompt, setup.grammar, setup.start, setup.examples)
    for repair in 0:max_repairs
        t = time()
        response = generate(model, messages; seed)
        attempt = _judge(setup, response, time() - t; sample, repair)
        push!(attempts, attempt)
        @debug "LLM attempt" sample repair attempt.code attempt.error fitness(attempt)

        _is_solution(attempt, setup) && return attempt.program
        push!(
            messages, ChatMessage("assistant", response),
            ChatMessage("user", feedback_message(prompt, attempt))
        )
    end
    return nothing
end

# Good enough to stop: a valid program that solves every example, or, without an
# interpreter to check it, any valid program.
_is_solution(a::Attempt, setup::_Setup) =
    !isnothing(a.program) && (isnothing(setup.interpret) || fitness(a) == 1)

# The valid program with the highest fitness, or `nothing` if no answer parsed.
function _best_program(attempts)
    valid = filter(a -> !isnothing(a.program), attempts)
    return isempty(valid) ? nothing : argmax(fitness, valid).program
end

# Parse a model answer and, with an interpreter, score it on the examples.
function _judge(setup::_Setup, response, seconds; sample, repair)
    program, error = try
        text2rulenode(response, setup.grammar, setup.start), nothing
    catch e
        e isa GrammarParseError || rethrow()
        nothing, e.message
    end
    evaluations = isnothing(program) || isnothing(setup.interpret) ? nothing :
        evaluate(program, setup.examples, setup.interpret, setup.eq)
    code = something(extract_code(response), "")
    return Attempt(sample, repair, response, code, program, error, evaluations, seconds)
end

"""
    evaluate(program, examples, interpret, eq = (==)) -> Vector{Evaluation}

Run `interpret(program, example.in)` on every example. An exception counts as a
wrong output and is kept as the evaluation's `output`.
"""
function evaluate(program, examples, interpret, eq = (==))
    return map(examples) do ex
        output = try
            interpret(program, ex.in)
        catch e
            e isa InterruptException && rethrow()
            e
        end
        Evaluation(ex, output, !(output isa Exception) && eq(output, ex.out))
    end
end

end # module LLMBaseline
