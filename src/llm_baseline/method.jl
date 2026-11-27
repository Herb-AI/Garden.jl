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

    attempts = Attempt[]
    for sample in 1:num_samples
        solution = _run_sample!(
            attempts, model, prompt;
            grammar, start = starting_sym, examples = problem.spec, interpret, eq,
            sample, max_repairs, seed = isnothing(seed) ? nothing : seed + sample - 1
        )
        isnothing(solution) || return solution, attempts
    end
    return _best_program(attempts), attempts
end

# One conversation: ask, parse, evaluate and give feedback, up to `max_repairs`
# times. Appends every attempt to `attempts`; returns the solution, or `nothing`.
function _run_sample!(
        attempts, model, prompt;
        grammar, start, examples, interpret, eq, sample, max_repairs, seed
    )
    messages = initial_messages(prompt, grammar, start, examples)
    for repair in 0:max_repairs
        t = time()
        response = generate(model, messages; seed)
        seconds = time() - t

        program, error = _parse(response, grammar, start)
        evaluations = isnothing(program) || isnothing(interpret) ? nothing :
            evaluate(program, examples, interpret, eq)
        code = something(extract_code(response), "")
        attempt = Attempt(sample, repair, response, code, program, error, evaluations, seconds)
        push!(attempts, attempt)
        @debug "LLM attempt" sample repair attempt.code attempt.error fitness(attempt)

        _is_solution(attempt, interpret) && return attempt.program
        push!(
            messages, ChatMessage("assistant", response),
            ChatMessage("user", feedback_message(prompt, attempt))
        )
    end
    return nothing
end

# `(program, nothing)`, or `(nothing, reason)` if the answer cannot be parsed into the grammar.
function _parse(response, grammar, start)
    try
        return text2rulenode(response, grammar, start), nothing
    catch e
        e isa GrammarParseError || rethrow()
        return nothing, e.message
    end
end

# Good enough to stop: a valid program that solves every example, or, without an
# interpreter to check it, any valid program.
_is_solution(a::Attempt, interpret) = !isnothing(a.program) && (isnothing(interpret) || fitness(a) == 1)

# The valid program with the highest fitness, or `nothing` if no answer parsed.
function _best_program(attempts)
    valid = filter(a -> !isnothing(a.program), attempts)
    return isempty(valid) ? nothing : argmax(fitness, valid).program
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
