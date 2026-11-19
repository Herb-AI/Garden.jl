module LLMBaseline

import Downloads
import JSON
import DocStringExtensions: TYPEDSIGNATURES
import Herb: AbstractGrammar, AbstractRuleNode, RuleNode, Problem, IOExample

include("backends.jl")
include("parsing.jl")

"""
    Attempt

One model call made by [`llm_synth`](@ref).

- `sample`, `round`: which independent sample, and which repair round within it
  (0 = the first answer).
- `response`: the model's full answer.
- `code`: the program text extracted from it (`""` if none).
- `program`: the parsed `RuleNode`, or `nothing` if the answer could not be parsed.
- `error`: why the answer could not be parsed, or `nothing`.
- `fitness`: fraction of examples solved; `missing` without an interpreter or
  program.
- `failures`: `(example, output)` for each failed example, where `output` is the
  program's output or the exception it threw.
- `seconds`: time taken by the model call.
"""
struct Attempt
    sample::Int
    round::Int
    response::String
    code::String
    program::Union{Nothing, RuleNode}
    error::Union{Nothing, String}
    fitness::Union{Missing, Float64}
    failures::Vector{Tuple{IOExample, Any}}
    seconds::Float64
end

include("prompts.jl")

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
- `interpret = nothing`: `interpret(program, example::IOExample)` returning the
  program's output. HerbInterpret's generated interpreters have this method.
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
        problem::Problem;
        model::AbstractLanguageModel = OllamaModel(DEFAULT_OLLAMA_MODEL),
        prompt::AbstractPrompt = DEFAULT_PROMPT,
        interpret = nothing,
        num_samples::Int = 1,
        max_repairs::Int = 0,
        eq = (==),
        seed::Union{Nothing, Int} = nothing
    )
    starting_sym in grammar.types ||
        throw(ArgumentError("starting symbol `$starting_sym` is not a nonterminal of the grammar"))
    num_samples >= 1 || throw(ArgumentError("num_samples must be at least 1"))
    max_repairs >= 0 || throw(ArgumentError("max_repairs must be non-negative"))

    examples = problem.spec
    attempts = Attempt[]
    for sample in 1:num_samples
        messages = initial_messages(prompt, grammar, starting_sym, examples)
        for round in 0:max_repairs
            t = time()
            response = generate(model, messages; seed = isnothing(seed) ? nothing : seed + sample - 1)
            attempt = _judge(response, time() - t, grammar, starting_sym, examples, interpret, eq;
                sample, round)
            push!(attempts, attempt)
            @debug "LLM attempt" sample round attempt.code attempt.error attempt.fitness

            if !isnothing(attempt.program) && (isnothing(interpret) || attempt.fitness == 1)
                return attempt.program, attempts
            end
            push!(messages, ChatMessage("assistant", response),
                ChatMessage("user", feedback_message(prompt, attempt)))
        end
    end

    valid = filter(a -> !isnothing(a.program), attempts)
    isempty(valid) && return nothing, attempts
    return argmax(a -> a.fitness, valid).program, attempts
end

# Parse a model answer and, with an interpreter, score it on the examples.
function _judge(response, seconds, grammar, start, examples, interpret, eq; sample, round)
    program, error = try
        text2rulenode(response, grammar, start), nothing
    catch e
        e isa GrammarParseError || rethrow()
        nothing, e.message
    end
    fitness, failures = isnothing(program) || isnothing(interpret) ?
        (missing, Tuple{IOExample, Any}[]) : evaluate(program, examples, interpret, eq)
    code = something(extract_code(response), "")
    return Attempt(sample, round, response, code, program, error, fitness, failures, seconds)
end

"""
    evaluate(program, examples, interpret, eq = (==)) -> (fitness, failures)

Run `program` on every example. `fitness` is the fraction of examples whose output
matches; `failures` holds `(example, output)` for the others, where `output` is
the exception if the program threw one.
"""
function evaluate(program, examples, interpret, eq = (==))
    failures = Tuple{IOExample, Any}[]
    for ex in examples
        output = try
            interpret(program, ex)
        catch e
            e isa InterruptException && rethrow()
            e
        end
        if output isa Exception || !eq(output, ex.out)
            push!(failures, (ex, output))
        end
    end
    return 1 - length(failures) / length(examples), failures
end

end # module LLMBaseline
