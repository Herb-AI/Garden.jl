module LLMBaseline

import Downloads
import JSON
import DocStringExtensions: TYPEDSIGNATURES
import Herb: AbstractGrammar, AbstractRuleNode, RuleNode, Problem, IOExample, rulenode2expr

include("backends.jl")
include("prompts.jl")
include("parsing.jl")

"""
    Attempt

One model call made by [`llm_synth`](@ref).

- `sample`, `round`: which independent sample and which repair round (0 = the
  first answer) this is.
- `response`: visible model answer (reasoning removed).
- `code`: extracted program text (`""` if none).
- `program`: parsed `RuleNode`, or `nothing`.
- `error`: `GrammarParseError` or exception from the model call, or `nothing`.
- `fitness`: fraction of examples solved (`missing` if not evaluated).
- `seconds`: wall-clock time of the model call.
"""
struct Attempt
    sample::Int
    round::Int
    response::String
    code::String
    program::Union{Nothing, RuleNode}
    error::Union{Nothing, Exception}
    fitness::Union{Missing, Float64}
    seconds::Float64
end

"""
    LLMSynthLog

Everything that happened during a call to [`llm_synth`](@ref): the `messages` of
the first prompt, all `attempts`, whether an exact solution was found
(`solved`), the fitness of the returned program (`best_fitness`, `missing` when
no interpreter was given) and the total time.
"""
struct LLMSynthLog
    prompt::Vector{ChatMessage}
    attempts::Vector{Attempt}
    solved::Bool
    best_fitness::Union{Missing, Float64}
    seconds::Float64
end

function Base.show(io::IO, log::LLMSynthLog)
    n_parsed = count(a -> !isnothing(a.program), log.attempts)
    print(io, "LLMSynthLog(", length(log.attempts), " model calls, ", n_parsed,
        " valid programs, solved = ", log.solved, ", best fitness = ", log.best_fitness,
        ", ", round(log.seconds; digits = 1), " s)")
end

"""
    $(TYPEDSIGNATURES)

Synthesize a program for `problem` in `grammar`, starting from `starting_sym`, by
prompting a language model.

The model sees the grammar and the examples (by default nothing else, see
[`DEFAULT_PROMPT`](@ref)) and answers with a program in the grammar's concrete
syntax. The answer is parsed back into a derivation of the grammar, so the
returned program is a `RuleNode` that is guaranteed to be derivable from
`starting_sym`.

The procedure draws `num_samples` independent answers. If an `interpret`
function is given, each candidate is run on the examples; the first one that
solves all examples is returned immediately and otherwise the candidate with the
highest fitness is returned. Without `interpret`, the first candidate that is a
valid program of the grammar is returned (no semantic check).

With `max_repairs > 0`, an unsuccessful answer is followed by a feedback message
(the parse error, or the examples on which the candidate fails, together with
its actual outputs) and the model gets another try within the same
conversation. Feedback only ever contains examples from the specification, so
the setting stays purely inductive.

# Keyword arguments
- `model::AbstractLanguageModel = OllamaModel(DEFAULT_OLLAMA_MODEL)`: the
  language model. See [`OllamaModel`](@ref),
  [`FunctionModel`](@ref) and `RECOMMENDED_MODELS`.
- `prompt::AbstractPrompt = DEFAULT_PROMPT`: prompting strategy, see
  [`PromptTemplate`](@ref).
- `interpret = nothing`: callable `interpret(program::RuleNode, example::IOExample)`
  returning the program's output on the example. The interpreters produced by
  `HerbInterpret.make_interpreter` and `make_stateful_interpreter` (and hence
  those in HerbBenchmarks) already have this method.
- `num_samples::Int = 1`: independent samples (use a non-zero temperature).
- `max_repairs::Int = 0`: feedback rounds per sample.
- `prompt_examples = nothing`: number of examples shown in the prompt (the first
  `prompt_examples`; `nothing` = all). Candidates are always checked on all
  examples.
- `eq = (==)`: predicate `eq(actual, expected)` comparing outputs.
- `allow_errors::Bool = true`: treat interpreter exceptions as failed examples
  (otherwise rethrow).
- `seed = nothing`: base seed; sample `i` uses `seed + i - 1`.
- `verbose::Bool = false`: log each attempt with `@info`.

# Returns
`(program, log)` where `program` is a `RuleNode` or `nothing` (no answer could
be parsed into the grammar) and `log` is an [`LLMSynthLog`](@ref).
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
        prompt_examples::Union{Nothing, Int} = nothing,
        eq = (==),
        allow_errors::Bool = true,
        seed::Union{Nothing, Int} = nothing,
        verbose::Bool = false
    )
    starting_sym in grammar.types ||
        throw(ArgumentError("starting symbol `$starting_sym` is not a nonterminal of the grammar"))
    num_samples >= 1 || throw(ArgumentError("num_samples must be at least 1"))
    max_repairs >= 0 || throw(ArgumentError("max_repairs must be non-negative"))

    t0 = time()
    all_examples = collect(problem.spec)
    shown = isnothing(prompt_examples) ? all_examples :
        all_examples[1:min(prompt_examples, length(all_examples))]
    first_messages = initial_messages(prompt, grammar, starting_sym, shown)

    attempts = Attempt[]
    best = nothing
    best_fitness = -1.0

    for sample in 1:num_samples
        messages = copy(first_messages)
        sample_seed = isnothing(seed) ? nothing : seed + sample - 1
        for rnd in 0:max_repairs
            attempt, feedback = _attempt(
                model, messages, grammar, starting_sym, all_examples, shown;
                sample, round = rnd, seed = sample_seed, interpret, eq, allow_errors
            )
            push!(attempts, attempt)
            verbose && _log_attempt(attempt)

            if !isnothing(attempt.program)
                fit = ismissing(attempt.fitness) ? 1.0 : attempt.fitness
                if fit > best_fitness
                    best, best_fitness = attempt.program, fit
                end
                if fit == 1.0
                    solved = !ismissing(attempt.fitness)
                    return best, LLMSynthLog(first_messages, attempts, solved,
                        attempt.fitness, time() - t0)
                end
            end
            (rnd == max_repairs || isnothing(feedback)) && break
            push!(messages, ChatMessage("assistant", attempt.response))
            push!(messages, ChatMessage("user",
                feedback_message(prompt, grammar, starting_sym, feedback)))
        end
    end

    fitness = isnothing(best) ? missing : (isnothing(interpret) ? missing : best_fitness)
    return best, LLMSynthLog(first_messages, attempts, false, fitness, time() - t0)
end

# One model call plus parsing and evaluation. Returns the attempt and the
# feedback to give if the attempt is not a solution (or `nothing` if the model
# call itself failed, in which case we do not continue the conversation).
function _attempt(
        model, messages, grammar, start, all_examples, shown;
        sample, round, seed, interpret, eq, allow_errors
    )
    t = time()
    response = try
        generate(model, messages; seed = seed)
    catch e
        e isa InterruptException && rethrow()
        @warn "Model call failed" exception = e
        return Attempt(sample, round, "", "", nothing, e, missing, time() - t), nothing
    end
    dt = time() - t

    code = ""
    program = try
        rn, code = text2rulenode(response, grammar, start)
        rn
    catch e
        e isa GrammarParseError || rethrow()
        c = extract_code(response)
        code = isnothing(c) ? "" : c
        fb = Feedback(e.kind, code, e.message, Tuple{Any, Any}[], length(shown))
        return Attempt(sample, round, response, code, nothing, e, missing, dt), fb
    end

    isnothing(interpret) && return Attempt(sample, round, response, code, program, nothing, missing, dt), nothing

    failures = Tuple{Any, Any}[]
    solved = 0
    for ex in all_examples
        out = _run(interpret, program, ex, allow_errors)
        ok = !(out isa _Failed) && _safe_eq(eq, out, ex.out)
        solved += ok
        if !ok && any(s -> s === ex, shown)
            push!(failures, (ex, out isa _Failed ? out.err : out))
        end
    end
    fitness = solved / length(all_examples)
    fb = Feedback(:wrong, code, "", failures, length(shown))
    return Attempt(sample, round, response, code, program, nothing, fitness, dt), fb
end

struct _Failed
    err::Exception
end

function _run(interpret, program, ex, allow_errors)
    allow_errors || return interpret(program, ex)
    try
        return interpret(program, ex)
    catch e
        e isa InterruptException && rethrow()
        return _Failed(e)
    end
end

function _safe_eq(eq, a, b)
    try
        return eq(a, b) === true
    catch
        return false
    end
end

function _log_attempt(a::Attempt)
    status = !isnothing(a.error) ? "error: " * first(sprint(showerror, a.error), 200) :
        ismissing(a.fitness) ? "valid program (not evaluated)" : "fitness $(a.fitness)"
    secs = round(a.seconds; digits = 1)
    @info "LLM attempt" sample = a.sample repair_round = a.round seconds = secs code = a.code status
end

end # module LLMBaseline
