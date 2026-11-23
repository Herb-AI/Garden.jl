#=
Opt-in checks of the LLM baseline against every benchmark in HerbBenchmarks.jl:

- every program in a sample of random programs prints and parses back to itself;
- no prompt or feedback message reveals a module name or problem name;
- each benchmark's interpreter works with the `interpret(program, input)` convention.

HerbBenchmarks is not a registered package, so these tests run from an environment
that has both Garden and HerbBenchmarks (the README's installation section):

    GARDEN_BENCHMARK_TESTS=true julia --project=<that environment> test/test_llm_baseline_benchmarks.jl
=#

using Test

if !(lowercase(get(ENV, "GARDEN_BENCHMARK_TESTS", "false")) in ("1", "true", "yes"))
    @info "Skipping LLM baseline benchmark tests (set GARDEN_BENCHMARK_TESTS=true to run them)."
else
    using Herb, HerbBenchmarks, Random
    import Garden.LLMBaseline as BL

    # Each benchmark with its interpreter in the `interpret(program, input)` form,
    # or `nothing` when the benchmark has none.
    benchmark_interpreters = [
        HerbBenchmarks.PBE_SLIA_Track_2019 => g -> HerbBenchmarks.PBE_SLIA_Track_2019.make_SLIA_interpreter(g),
        HerbBenchmarks.PBE_BV_Track_2018 => g -> HerbBenchmarks.PBE_BV_Track_2018.make_bv_interpreter(g),
        HerbBenchmarks.DeepCoder_2016 => g -> HerbBenchmarks.DeepCoder_2016.make_deepcoder_interpreter(g),
        HerbBenchmarks.String_transformations_2020 =>
            _ -> (p, input) -> HerbBenchmarks.String_transformations_2020.interpret(p, input[:_arg_1]),
        HerbBenchmarks.Robots_2020 => _ -> (p, input) -> HerbBenchmarks.Robots_2020.interpret(p, input[:_arg_1_]),
        HerbBenchmarks.Pixels_2020 => _ -> (p, input) -> HerbBenchmarks.Pixels_2020.interpret(p, input[:_arg_1]),
        HerbBenchmarks.Abstract_Reasoning_2019 => _ -> nothing,
    ]

    leaks(text, benchmark) = any(w -> occursin(w, text), ("HerbBenchmarks", string(nameof(benchmark)), "problem_"))

    Random.seed!(1)
    @testset verbose = true "LLM baseline on HerbBenchmarks" begin
        @testset "$(nameof(benchmark))" for (benchmark, make_interpreter) in benchmark_interpreters
            programs_run = 0
            outputs_produced = 0
            for pair in first(get_all_problem_grammar_pairs(benchmark), 10)
                g = pair.grammar
                programs = RuleNode[]
                for _ in 1:20
                    try
                        push!(programs, rand(RuleNode, g, :Start, 5))
                    catch  # some grammars have no program of depth 5 from this start
                    end
                end

                # The parser reads back every program the way the prompt prints it.
                for p in programs
                    e = rulenode2expr(p, g)
                    back = BL.text2rulenode("```julia\n" * BL.rule_string(e) * "\n```", g, :Start)
                    @test BL.normalize_expr(rulenode2expr(back, g)) == BL.normalize_expr(e)
                end

                # The prompt reveals nothing but the grammar and the examples.
                prompt = join((m.content for m in BL.initial_messages(BL.DEFAULT_PROMPT, g, :Start, pair.problem.spec)), "\n")
                @test !leaks(prompt, benchmark)

                # Feedback on a (random, almost surely wrong) program reveals nothing either.
                interpret = make_interpreter(g)
                (isnothing(interpret) || isempty(programs)) && continue
                fitness, failures = BL.evaluate(first(programs), pair.problem.spec, interpret)
                attempt = BL.Attempt(1, 0, "", "", first(programs), nothing, fitness, failures, 0.0)
                @test !leaks(BL.feedback_message(BL.DEFAULT_PROMPT, attempt), benchmark)
                programs_run += 1
                outputs_produced += count(f -> !(last(f) isa Exception), failures) +
                    length(pair.problem.spec) - length(failures)
            end
            # A wrongly wired interpreter throws on every example.
            programs_run > 0 && @test outputs_produced > 0
        end
    end
end
