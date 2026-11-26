#=
Language-model backends: subtypes of `AbstractLanguageModel` with a `generate`
method (see `types.jl`). A new backend only needs those two things.
=#

"""
    OllamaModel(model::AbstractString; host, think, options, timeout)

A model served by [Ollama](https://ollama.com), called through its native
`/api/chat` endpoint.

- `host = "http://localhost:11434"`: the Ollama server.
- `think = nothing`: reasoning control: `true`/`false` for hybrid models (Qwen,
  Gemma), `"low"`/`"medium"`/`"high"` for gpt-oss, `nothing` for the model default.
- `options = Dict()`: Ollama options such as `"temperature"`, `"num_ctx"` or
  `"num_predict"`. `"num_ctx"` defaults to 32768, because reasoning traces easily
  exceed Ollama's own small default.
- `timeout = 1800`: request timeout in seconds.

```julia
OllamaModel("gpt-oss:20b"; think = "medium", options = Dict("temperature" => 0.6))
```
"""
Base.@kwdef struct OllamaModel <: AbstractLanguageModel
    model::String
    host::String = "http://localhost:11434"
    think::Union{Nothing, Bool, String} = nothing
    options::Dict{String, Any} = Dict{String, Any}()
    timeout::Float64 = 1800.0
end
OllamaModel(model::AbstractString; kwargs...) = OllamaModel(; model = String(model), kwargs...)

function generate(m::OllamaModel, messages::Vector{ChatMessage}; seed = nothing)
    options = merge(Dict{String, Any}("num_ctx" => 32768), m.options)
    isnothing(seed) || (options["seed"] = seed)
    body = Dict{String, Any}(
        "model" => m.model,
        "messages" => [Dict("role" => x.role, "content" => x.content) for x in messages],
        "stream" => false,
        "options" => options
    )
    isnothing(m.think) || (body["think"] = m.think)
    response = _post_json(rstrip(m.host, '/') * "/api/chat", body; timeout = m.timeout)
    return string(response["message"]["content"])
end

"""
    FunctionModel(f)

Wrap a function `f(messages::Vector{ChatMessage}) -> String` as a language
model, e.g. to script answers in tests.
"""
struct FunctionModel{F} <: AbstractLanguageModel
    f::F
end

generate(m::FunctionModel, messages::Vector{ChatMessage}; seed = nothing) = string(m.f(messages))

function _post_json(url::AbstractString, body; timeout::Real)
    output = IOBuffer()
    response = Downloads.request(
        url; method = "POST", headers = ["Content-Type" => "application/json"],
        input = IOBuffer(JSON.json(body)), output = output,
        timeout = timeout, throw = false
    )
    text = String(take!(output))
    response isa Downloads.RequestError &&
        error("Request to $url failed: $(response.message). Is Ollama running?")
    200 <= response.status < 300 ||
        error("Request to $url returned HTTP $(response.status): $text")
    return JSON.parse(text)
end

"""
Open-weight models that fit a well-equipped laptop and are good candidates for
this baseline, as of November 2026: the Ollama tag, the approximate memory needed
at 4-bit quantisation and a short note. See the README for the reasoning behind
the selection.
"""
const RECOMMENDED_MODELS = [
    (
        name = "gpt-oss-20b", ollama = "gpt-oss:20b",
        memory_gb = 16, reasoning = true,
        note = "Default. 21B MoE (~3.6B active): fast, strong reasoning; set think=\"high\" for hard tasks.",
    ),
    (
        name = "Qwen3.8-27B", ollama = "qwen3.8:27b",
        memory_gb = 24, reasoning = true,
        note = "Strongest dense model in this size class; slower than the MoE models.",
    ),
    (
        name = "Gemma 4 26B A4B", ollama = "gemma4:26b",
        memory_gb = 20, reasoning = true,
        note = "MoE (~3.8B active): fast, good reasoning.",
    ),
    (
        name = "Gemma 4 31B", ollama = "gemma4:31b",
        memory_gb = 24, reasoning = true,
        note = "Dense; higher quality than the 26B MoE, slower.",
    ),
    (
        name = "Qwen3-Coder-30B-A3B", ollama = "qwen3-coder:30b",
        memory_gb = 20, reasoning = false,
        note = "Non-reasoning code model: a cheap 'no thinking' baseline.",
    ),
    (
        name = "Qwen3.5-9B", ollama = "qwen3.5:9b",
        memory_gb = 8, reasoning = true,
        note = "Small-model baseline.",
    ),
    (
        name = "Qwen3.5-4B", ollama = "qwen3.5:4b",
        memory_gb = 4, reasoning = true,
        note = "Smallest useful baseline.",
    ),
]

"""
The Ollama tag used when no model is given to [`llm_synth`](@ref).
"""
const DEFAULT_OLLAMA_MODEL = "gpt-oss:20b"
