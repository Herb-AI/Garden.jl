#=
Language-model backends: subtypes of `AbstractLanguageModel` with a `generate`
method (see `types.jl`). A new backend only needs those two things.
=#

"""
    OllamaModel(model::AbstractString; host, think, options, timeout, idle_timeout)

A model served by [Ollama](https://ollama.com), called through its native
`/api/chat` endpoint.

- `host = "http://localhost:11434"`: the Ollama server.
- `think = nothing`: reasoning control: `true`/`false` for hybrid models (Qwen,
  Gemma), `"low"`/`"medium"`/`"high"` for gpt-oss, `nothing` for the model default.
- `options = Dict()`: Ollama options such as `"temperature"`, `"num_ctx"` or
  `"num_predict"`. `"num_ctx"` defaults to 32768, because reasoning traces easily
  exceed Ollama's own small default.
- `timeout = 1800`: limit in seconds on the whole request.
- `idle_timeout = 300`: limit in seconds on *silence*. The answer is streamed, so
  the server sends a chunk per token and a longer gap means it really is gone.
  It has to cover the first chunk too, which waits for the model to be loaded.

A small reasoning model can spend many thousands of tokens on a trivial task,
which makes a request look stalled when it is only slow. Run with
`JULIA_DEBUG=Garden` to see the chunks arrive, and pass `think = false` or a
`"num_predict"` option to put a stop to it.

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
    idle_timeout::Float64 = 300.0
end
OllamaModel(model::AbstractString; kwargs...) = OllamaModel(; model = String(model), kwargs...)

function generate(m::OllamaModel, messages::Vector{ChatMessage}; seed = nothing)
    options = merge(Dict{String, Any}("num_ctx" => 32768), m.options)
    isnothing(seed) || (options["seed"] = seed)
    body = Dict{String, Any}(
        "model" => m.model,
        "messages" => [Dict("role" => x.role, "content" => x.content) for x in messages],
        "stream" => true,
        "options" => options
    )
    isnothing(m.think) || (body["think"] = m.think)

    content = IOBuffer()
    chunks, thinking_chunks, started, last_report = 0, 0, time(), time()
    done_reason = nothing
    _stream_json_lines(
        rstrip(m.host, '/') * "/api/chat", body;
        timeout = m.timeout, idle_timeout = m.idle_timeout
    ) do chunk
        message = get(chunk, "message", nothing)
        if message isa AbstractDict
            text = get(message, "content", nothing)
            text isa AbstractString && write(content, text)
            reasoning = get(message, "thinking", nothing)
            reasoning isa AbstractString && !isempty(reasoning) && (thinking_chunks += 1)
        end
        get(chunk, "done", false) === true && (done_reason = get(chunk, "done_reason", nothing))
        chunks += 1
        # A long answer is otherwise indistinguishable from a hung connection.
        if time() - last_report >= 10
            @debug "Ollama is generating" model = m.model chunks thinking_chunks seconds = round(time() - started, digits = 1)
            last_report = time()
        end
    end
    answer = String(take!(content))
    seconds = round(time() - started, digits = 1)
    @debug "Ollama answered" model = m.model chunks thinking_chunks answer_chars = length(answer) seconds done_reason
    # `num_predict` counts the reasoning tokens too, so a limit that is too low
    # cuts the answer off before the program, or before any content at all.
    if done_reason == "length"
        detail = isempty(answer) ?
            "no content at all: every token went into the reasoning trace" :
            "the answer is cut off and may hold no program"
        @warn "Ollama hit the \"num_predict\" token limit, so $detail." model = m.model num_predict = get(
            options, "num_predict", nothing
        ) maxlog = 1
    end
    return answer
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

# Ollama answers `/api/chat` with one JSON object per line when `"stream"` is set,
# and holds everything back until the answer is finished when it is not. Streaming
# is what tells a stalled request from a slow one: data keeps arriving
# while the model writes, so silence is a real failure and `idle_timeout` can be
# left on, and `on_chunk` sees the answer being built.
function _stream_json_lines(on_chunk, url::AbstractString, body; timeout::Real, idle_timeout::Real)
    downloader = Downloads.Downloader()
    # `Downloads` aborts a request that receives nothing for 20 seconds by default,
    # which is far too short when the model still has to be loaded.
    downloader.easy_hook = (easy, info) -> begin
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_LIMIT, Clong(1))
        Downloads.Curl.setopt(easy, Downloads.Curl.CURLOPT_LOW_SPEED_TIME, round(Clong, idle_timeout))
    end

    # `Downloads.request` fills `stream` while the loop below drains it, so the
    # request runs in a task of its own.
    stream = Base.BufferStream()
    request = @async try
        Downloads.request(
            url; method = "POST", headers = ["Content-Type" => "application/json"],
            input = IOBuffer(JSON.json(body)), output = stream,
            timeout = timeout, throw = false, downloader = downloader
        )
    finally
        close(stream)
    end

    # A request that fails answers with one JSON object instead of a stream, so the
    # start of the text is kept to report it once the status is known. A model that
    # falls into a repetition loop sends megabytes, hence the limit.
    text = IOBuffer()
    try
        while !eof(stream)
            line = readline(stream)
            text.size < 8192 && write(text, line, '\n')
            isempty(strip(line)) && continue
            chunk = try
                JSON.parse(line)
            catch
                continue    # not a chunk; `text` keeps it for the error below
            end
            chunk isa AbstractDict || continue
            haskey(chunk, "error") && error("Request to $url failed: $(chunk["error"])")
            on_chunk(chunk)
        end
    catch
        # Hang up instead of leaving the request running in the background.
        close(stream)
        try
            wait(request)
        catch
        end
        rethrow()
    end

    response = fetch(request)
    response isa Downloads.RequestError &&
        error("Request to $url failed: $(response.message). Is Ollama running?")
    200 <= response.status < 300 ||
        error("Request to $url returned HTTP $(response.status): $(String(take!(text)))")
    return nothing
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
