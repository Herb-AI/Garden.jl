#=
Language-model backends.

Models are served by Ollama (`OllamaModel`). `FunctionModel` wraps a plain Julia
function, which the tests use to script answers without a server. A backend is
any subtype of `AbstractLanguageModel` that implements

    generate(model, messages::Vector{ChatMessage}; seed = nothing) -> String

and returns the *visible* answer of the model (reasoning traces stripped).
Everything else in the baseline (prompting, parsing, verification) is
backend-agnostic, so adding a new backend is a matter of implementing that one
method.
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
Abstract supertype of all language-model backends. Subtypes implement
[`generate`](@ref).
"""
abstract type AbstractLanguageModel end

"""
    generate(model::AbstractLanguageModel, messages::Vector{ChatMessage}; seed = nothing) -> String

Send `messages` to `model` and return the text of its answer, with any
reasoning trace removed. `seed` is forwarded to backends that support it, so
repeated samples can be made reproducible.
"""
function generate end

# ---------------------------------------------------------------------------
# Ollama (native API)
# ---------------------------------------------------------------------------

"""
    OllamaModel(model::AbstractString; kwargs...)

A model served by [Ollama](https://ollama.com) through its native `/api/chat`
endpoint, which (unlike Ollama's OpenAI-compatible `/v1` endpoint) lets us set
the context window, which matters for reasoning models whose traces easily exceed
Ollama's small default.

# Keyword arguments
- `host = "http://localhost:11434"`: Ollama server.
- `temperature = nothing`: sampling temperature (`nothing` = model default).
- `num_ctx = 32768`: context window in tokens.
- `num_predict = nothing`: maximum number of generated tokens.
- `think = nothing`: reasoning control. `true`/`false` for hybrid models
  (Qwen, Gemma), or `"low"`/`"medium"`/`"high"` for gpt-oss. `nothing` leaves the
  model default.
- `options = Dict{String,Any}()`: extra Ollama `options` (e.g. `"top_p"`).
- `timeout = 1800`: request timeout in seconds.

# Example
```julia
model = OllamaModel("gpt-oss:20b"; think = "medium", temperature = 0.6)
```
"""
Base.@kwdef struct OllamaModel <: AbstractLanguageModel
    model::String
    host::String = "http://localhost:11434"
    temperature::Union{Nothing, Float64} = nothing
    num_ctx::Union{Nothing, Int} = 32768
    num_predict::Union{Nothing, Int} = nothing
    think::Union{Nothing, Bool, String} = nothing
    options::Dict{String, Any} = Dict{String, Any}()
    timeout::Float64 = 1800.0
end
OllamaModel(model::AbstractString; kwargs...) = OllamaModel(; model = String(model), kwargs...)

function generate(m::OllamaModel, messages::Vector{ChatMessage}; seed = nothing)
    options = Dict{String, Any}(m.options)
    isnothing(m.temperature) || (options["temperature"] = m.temperature)
    isnothing(m.num_ctx) || (options["num_ctx"] = m.num_ctx)
    isnothing(m.num_predict) || (options["num_predict"] = m.num_predict)
    isnothing(seed) || (options["seed"] = seed)
    body = Dict{String, Any}(
        "model" => m.model,
        "messages" => [Dict("role" => x.role, "content" => x.content) for x in messages],
        "stream" => false,
        "options" => options
    )
    isnothing(m.think) || (body["think"] = m.think)
    response = _post_json(rstrip(m.host, '/') * "/api/chat", body; timeout = m.timeout)
    content = response["message"]["content"]
    return strip_reasoning(string(content))
end

# ---------------------------------------------------------------------------
# Plain Julia function
# ---------------------------------------------------------------------------

"""
    FunctionModel(f)

Wrap a Julia function `f(messages::Vector{ChatMessage}) -> String` as a
language model. Useful for tests and for replaying cached answers.
If `f` also accepts a `seed` keyword it is passed along.
"""
struct FunctionModel{F} <: AbstractLanguageModel
    f::F
end

function generate(m::FunctionModel, messages::Vector{ChatMessage}; seed = nothing)
    out = applicable(m.f, messages) && !_accepts_seed(m.f) ? m.f(messages) :
        m.f(messages; seed = seed)
    return strip_reasoning(string(out))
end

function _accepts_seed(f)
    return any(methods(f)) do meth
        :seed in Base.kwarg_decl(meth)
    end
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

"""
    strip_reasoning(text) -> String

Remove `<think>…</think>` style reasoning blocks that some models inline into
the answer.
"""
function strip_reasoning(text::AbstractString)
    text = replace(text, r"<think>.*?</think>"s => "")
    text = replace(text, r"<thinking>.*?</thinking>"s => "")
    # An unterminated trace (the model ran out of tokens) carries no answer.
    text = replace(text, r"<think>.*"s => "")
    return String(strip(text))
end

function _post_json(url::AbstractString, body; timeout::Real)
    output = IOBuffer()
    response = Downloads.request(
        url; method = "POST", headers = ["Content-Type" => "application/json"],
        input = IOBuffer(JSON.json(body)), output = output,
        timeout = timeout, throw = false
    )
    text = String(take!(output))
    if response isa Downloads.RequestError
        error("Request to $url failed: $(response.message). Is Ollama running?")
    end
    if !(200 <= response.status < 300)
        error("Request to $url returned HTTP $(response.status): $text")
    end
    return JSON.parse(text)
end

"""
Open-weight models that fit a well-equipped laptop and are good candidates for
this baseline, as of November 2026. Each entry gives the Ollama tag, the
approximate memory needed at 4-bit quantisation and a short note. See the README for the
reasoning behind the selection.
"""
const RECOMMENDED_MODELS = [
    (name = "gpt-oss-20b", ollama = "gpt-oss:20b",
        memory_gb = 16, reasoning = true,
        note = "Default. 21B MoE (~3.6B active): fast, strong reasoning; set think=\"high\" for hard tasks."),
    (name = "Qwen3.8-27B", ollama = "qwen3.8:27b",
        memory_gb = 24, reasoning = true,
        note = "Strongest dense model in this size class; slower than the MoE models."),
    (name = "Gemma 4 26B A4B", ollama = "gemma4:26b",
        memory_gb = 20, reasoning = true,
        note = "MoE (~3.8B active): fast, good reasoning."),
    (name = "Gemma 4 31B", ollama = "gemma4:31b",
        memory_gb = 24, reasoning = true,
        note = "Dense; higher quality than the 26B MoE, slower."),
    (name = "Qwen3-Coder-30B-A3B", ollama = "qwen3-coder:30b",
        memory_gb = 20, reasoning = false,
        note = "Non-reasoning code model: a cheap 'no thinking' baseline."),
    (name = "Qwen3.5-9B", ollama = "qwen3.5:9b",
        memory_gb = 8, reasoning = true,
        note = "Small-model baseline."),
    (name = "Qwen3.5-4B", ollama = "qwen3.5:4b",
        memory_gb = 4, reasoning = true,
        note = "Smallest useful baseline."),
]

"""
The Ollama tag used when no model is given to [`llm_synth`](@ref).
"""
const DEFAULT_OLLAMA_MODEL = "gpt-oss:20b"
