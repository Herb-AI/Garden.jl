#=
Live tests of the LLM baseline against a real model served by Ollama.

Disabled by default. Enable with

    GARDEN_LLM_TESTS=true julia --project -e 'using Pkg; Pkg.test()'

Optional settings:
- `GARDEN_LLM_MODEL` (default `qwen3.5:4b`): Ollama tag of the model to use.
- `GARDEN_LLM_HOST` (default `http://localhost:11434`): Ollama server.

The model must already be pulled (`ollama pull qwen3.5:4b`). Model answers are
non-deterministic, so these tests check that the pipeline works end to end on
real answers, and only expect the model to solve trivial tasks.
=#

using Test

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

import Garden.LLMBaseline as LiveLLM
import Herb: HerbCore, @csgrammar, IOExample, Problem, RuleNode, make_interpreter,
    rulenode2expr

const LIVE_LLM_TESTS = lowercase(get(ENV, "GARDEN_LLM_TESTS", "false")) in ("1", "true", "yes")

if !LIVE_LLM_TESTS
    @info "Skipping live LLM tests (set GARDEN_LLM_TESTS=true to run them)."
else
    live_model_tag = get(ENV, "GARDEN_LLM_MODEL", "qwen3.5:4b")
    live_host = get(ENV, "GARDEN_LLM_HOST", "http://localhost:11434")
    live_model = LiveLLM.OllamaModel(live_model_tag;
        host = live_host, temperature = 0.7, num_ctx = 16384, timeout = 600)

    @testset verbose = true "LLMBaseline live ($live_model_tag)" begin
        @testset "model answers" begin
            answer = LiveLLM.generate(live_model,
                [LiveLLM.ChatMessage("user", "Reply with the single word: ready")]; seed = 1)
            @test answer isa String
            @test !isempty(answer)
        end

        arith = @csgrammar begin
            Start = Int
            Int = Int + Int
            Int = Int * Int
            Int = |(1:2)
            Int = x
        end
        arith_interp = make_interpreter(arith; input_symbols = [:x],
            target_module = @__MODULE__, cache_module = @__MODULE__)

        @testset "solves x + 1" begin
            problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), x + 1) for x in 1:5])
            program, log = LiveLLM.llm_synth(arith, :Start, problem;
                model = live_model, interpret = arith_interp,
                num_samples = 3, max_repairs = 2, seed = 1)
            @info "x + 1" log program = isnothing(program) ? nothing : rulenode2expr(program, arith)
            @test any(a -> !isnothing(a.program), log.attempts)   # real answers parse
            @test log.solved
            @test program isa RuleNode
            @test all(arith_interp(program, ex) == ex.out for ex in problem.spec)
        end

        @testset "harder task returns a valid program or nothing" begin
            problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), 2x * x + 1) for x in 1:5])
            program, log = LiveLLM.llm_synth(arith, :Start, problem;
                model = live_model, interpret = arith_interp, max_repairs = 1, seed = 2)
            @info "2x^2 + 1" log program = isnothing(program) ? nothing : rulenode2expr(program, arith)
            @test length(log.attempts) >= 1
            if !isnothing(program)
                @test rulenode2expr(program, arith) isa Union{Expr, Symbol, Int}
                @test 0.0 <= log.best_fitness <= 1.0
            end
        end

        @testset "statement-sequence grammar" begin
            # Pure inductive task on an unfamiliar DSL: only well-formedness is required.
            seq = @csgrammar begin
                Start = Sequence
                Sequence = Operation
                Sequence = (Operation; Sequence)
                Operation = inc() | dbl()
            end
            problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), 2(x + 1)) for x in 1:3])
            program, log = LiveLLM.llm_synth(seq, :Start, problem;
                model = live_model, num_samples = 2, max_repairs = 2, seed = 3)
            @info "sequence DSL" log program = isnothing(program) ? nothing : rulenode2expr(program, seq)
            @test any(a -> !isnothing(a.program), log.attempts)
            @test program isa RuleNode
        end

        @testset "OpenAI-compatible endpoint" begin
            oai = LiveLLM.OpenAICompatibleModel(live_model_tag;
                base_url = rstrip(live_host, '/') * "/v1", temperature = 0.7, timeout = 600)
            answer = LiveLLM.generate(oai,
                [LiveLLM.ChatMessage("user", "Reply with the single word: ready")]; seed = 1)
            @test !isempty(answer)
        end
    end
end
