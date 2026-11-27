#=
Demo: streaming Ollama calls + the tightened prompt, against a real small model.

Run with:
    JULIA_DEBUG=Garden julia --project examples/demo_ollama_fix.jl

`JULIA_DEBUG=Garden` is what makes this worth running: you'll see "Ollama is
generating" every ~10s while tokens stream in, so a slow model is visibly
different from a hung connection. Without it you only see the final timing.

Needs Ollama running locally with `qwen3.5:4b` pulled:
    ollama pull qwen3.5:4b

Optional env vars:
- GARDEN_LLM_MODEL (default "qwen3.5:4b")
- GARDEN_LLM_HOST   (default "http://localhost:11434")
- GARDEN_LLM_THINK_DEMO=true  also runs the slow, thinking-enabled path for
  comparison (takes several minutes on a 4B model — off by default).
=#

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

import Garden.LLMBaseline as LLM
import Herb: HerbCore, @csgrammar, IOExample, Problem, make_interpreter, rulenode2expr

model_tag = get(ENV, "GARDEN_LLM_MODEL", "qwen3.5:4b")
host = get(ENV, "GARDEN_LLM_HOST", "http://localhost:11434")
run_think_demo = lowercase(get(ENV, "GARDEN_LLM_THINK_DEMO", "false")) in ("1", "true", "yes")

grammar = @csgrammar begin
    Start = Int
    Int = Int + Int
    Int = Int * Int
    Int = |(1:2)
    Int = x
end
interp = make_interpreter(
    grammar; input_symbols = [:x], target_module = @__MODULE__, cache_module = @__MODULE__
)
problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), x + 1) for x in 1:5])

function run(label, model)
    println("\n", "="^70)
    println(label, "  (model = $(model.model), think = $(model.think))")
    println("="^70)
    t = @elapsed program, attempts = LLM.llm_synth(
        grammar, :Start, problem;
        model, interpret = interp, num_samples = 3, max_repairs = 2, seed = 1
    )
    for a in attempts
        code = isnothing(a.program) ? "(unparsed)" : string(rulenode2expr(a.program, grammar))
        println("  sample=$(a.sample) repair=$(a.repair)  $(round(a.seconds, digits = 1))s  ",
            "fitness=$(LLM.fitness(a))  program=$code")
    end
    status = isnothing(program) ? "no solution found" : "solved: $(rulenode2expr(program, grammar))"
    println("-> $status in $(round(t, digits = 1))s total")
    return t
end

# This is the shipped configuration: streaming + think off + the tightened
# prompt + a num_predict cap. Should finish in single-digit seconds per call.
fast_model = LLM.OllamaModel(model_tag; host, think = false, options = Dict("num_predict" => 2048))
fast_t = run("Fast path (think = false, default prompt)", fast_model)

if run_think_demo
    # Same task, reasoning on. Watch the "Ollama is generating" debug lines:
    # thousands of tokens of thinking per call is normal for a small reasoning
    # model, which is why this used to look like a stall rather than a slow call.
    slow_model = LLM.OllamaModel(model_tag; host, think = true, timeout = 1800.0)
    slow_t = run("Slow path (think = true) — several minutes, for comparison", slow_model)
    println("\nSpeedup from think = false: $(round(slow_t / fast_t, digits = 1))x")
else
    println("\n(Set GARDEN_LLM_THINK_DEMO=true to also run the slow think=true path for comparison.)")
end
