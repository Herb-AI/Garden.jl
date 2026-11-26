#=
Types and interfaces shared by all files of the baseline. This file is included
first and depends on nothing else in the module.
=#

"""
    ChatMessage(role, content)

A single chat turn. `role` is `"system"` (the system prompt), `"user"` (user instructions) or `"assistant"` (feedback messages).
A typical interactions is:
- system: the rules
- user: grammar and examples
- assistant: the model's first answer, copied back
- user: "Your program is wrong on these examples: …"
"""
struct ChatMessage
    role::String
    content::String
end

"""
Abstract supertype of language-model backends. A subtype implements
[`generate`](@ref).
"""
abstract type AbstractLanguageModel end

"""
    generate(model::AbstractLanguageModel, messages::Vector{ChatMessage}; seed = nothing) -> String

Send `messages` to `model` and return the text of its answer.
"""
function generate end

"""
Abstract supertype of prompting strategies. A subtype implements
[`initial_messages`](@ref) and [`feedback_message`](@ref).
"""
abstract type AbstractPrompt end

"""
    initial_messages(prompt::AbstractPrompt, grammar, start::Symbol, examples) -> Vector{ChatMessage}

The conversation that starts each sample. It is never given the `Problem`, so
the problem's name cannot reach the model.
"""
function initial_messages end

"""
    feedback_message(prompt::AbstractPrompt, attempt::Attempt) -> String

The message that asks the model to repair a failed `attempt`. Only called when
`max_repairs > 0` in [`llm_synth`](@ref).
"""
function feedback_message end

"""
    GrammarParseError(message)

Thrown when a model answer cannot be turned into a program of the grammar.
"""
struct GrammarParseError <: Exception
    message::String
end
Base.showerror(io::IO, e::GrammarParseError) = print(io, e.message)

"""
    Evaluation(example, output, correct)

The result of running a program on one example.

- `example`: the `IOExample`.
- `output`: what the program returned, or the exception it threw.
- `correct`: whether `output` matched `example.out`, decided with the `eq` of
  [`llm_synth`](@ref) when the program was run.
"""
struct Evaluation
    example::IOExample
    output::Any
    correct::Bool
end

"""
    Attempt

One model call made by [`llm_synth`](@ref).

- `sample`, `repair`: which independent sample, and which repair round within it
  (0 = the first answer).
- `response`: the model's full answer.
- `code`: the program text extracted from it (`""` if none).
- `program`: the parsed `RuleNode`, or `nothing` if the answer could not be parsed.
- `error`: why the answer could not be parsed, or `nothing`.
- `evaluations`: one [`Evaluation`](@ref) per example, or `nothing` if the program
  was not run (no interpreter, or no program).
- `seconds`: time taken by the model call.

[`fitness`](@ref) and [`failures`](@ref) are computed from `evaluations`.
"""
struct Attempt
    sample::Int
    repair::Int
    response::String
    code::String
    program::Union{Nothing, RuleNode}
    error::Union{Nothing, String}
    evaluations::Union{Nothing, Vector{Evaluation}}
    seconds::Float64
end

"""
    fitness(attempt) -> Union{Float64, Missing}

The fraction of examples the attempt's program solves, or `missing` if it was not
run.
"""
function fitness(a::Attempt)
    isnothing(a.evaluations) && return missing
    return count(e -> e.correct, a.evaluations) / length(a.evaluations)
end

"""
    failures(attempt) -> Vector{Evaluation}

The evaluations on which the attempt's program was wrong or threw an exception
(empty if it was not run).
"""
failures(a::Attempt) = isnothing(a.evaluations) ? Evaluation[] : filter(e -> !e.correct, a.evaluations)
