#=
Types and interfaces shared by all files of the baseline. This file is included
first and depends on nothing else in the module.
=#

"""
    ChatMessage(role, content)

A single chat turn. `role` is `"system"`, `"user"` or `"assistant"`.
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
    Attempt

One model call made by [`llm_synth`](@ref).

- `sample`, `repair`: which independent sample, and which repair round within it
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
    repair::Int
    response::String
    code::String
    program::Union{Nothing, RuleNode}
    error::Union{Nothing, String}
    fitness::Union{Missing, Float64}
    failures::Vector{Tuple{IOExample, Any}}
    seconds::Float64
end
