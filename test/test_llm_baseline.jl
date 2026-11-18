using Test

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

import Garden.LLMBaseline as LLM
import Garden.LLMBaseline: llm_synth, FunctionModel, ChatMessage, PromptTemplate,
    GrammarParseError, text2rulenode, extract_code, format_grammar, format_value,
    initial_messages, DEFAULT_PROMPT, DEFAULT_USER_PROMPT, strip_reasoning
import Herb: HerbCore, @csgrammar, BFSIterator, IOExample, Problem, RuleNode, freeze_state,
    make_interpreter, rulenode2expr

# Primitives of a tiny sequence DSL used below.
module SeqDSL
struct Counter
    n::Int
end
inc(c::Counter) = Counter(c.n + 1)
dbl(c::Counter) = Counter(2c.n)
end

# Answers scripted replies in order and records every conversation it sees.
function scripted(replies)
    seen = Vector{Vector{ChatMessage}}()
    i = Ref(0)
    model = FunctionModel(messages -> begin
        push!(seen, copy(messages))
        i[] += 1
        replies[min(i[], length(replies))]
    end)
    return model, seen
end

@testset verbose = true "LLMBaseline" begin
    arith = @csgrammar begin
        Start = Int
        Int = Int + Int
        Int = Int * Int
        Int = (Bool ? Int : Int)
        Int = |(1:2)
        Int = x
        Bool = Int == Int
    end

    seq = @csgrammar begin
        Start = Sequence
        Sequence = Operation
        Sequence = (Operation; Sequence)
        Operation = inc() | dbl()
        Operation = REPEAT(Sequence)
    end

    @testset "extract_code" begin
        @test extract_code("blah\n```julia\nx + 1\n```\nmore\n```\nx * 2\n```") == "x * 2"
        @test extract_code("answer: `x + 2`") == "x + 2"
        @test extract_code("<think>```julia\nwrong\n```</think>\n```julia\nx\n```") == "x"
        @test extract_code("```julia\nx + 1") == "x + 1"         # unterminated block
        @test isnothing(extract_code("<think>only thinking"))
        @test strip_reasoning("<think>a\nb</think>\nhello") == "hello"
    end

    @testset "parsing into the grammar" begin
        rn, _ = text2rulenode("```julia\nx + 1 + 2\n```", arith, :Start)
        @test rulenode2expr(rn, arith) == :((x + 1) + 2)

        rn, _ = text2rulenode("```julia\nif x == 1\n  2\nelse\n  x * x\nend\n```", arith, :Start)
        @test rulenode2expr(rn, arith) == rulenode2expr(
            first(text2rulenode("`(x == 1) ? 2 : x * x`", arith, :Start)), arith)

        rn, _ = text2rulenode("```julia\nfunction f(x)\n  return x * 2\nend\n```", arith, :Start)
        @test rulenode2expr(rn, arith) == :(x * 2)

        # Flat statement sequences are re-nested to match `(Operation; Sequence)`.
        rn, _ = text2rulenode("```julia\ninc()\ndbl()\nREPEAT(inc(); dbl())\n```", seq, :Start)
        expr = rulenode2expr(rn, seq)
        @test LLM.normalize_expr(expr) ==
            LLM.normalize_expr(:(inc(); (dbl(); REPEAT((inc(); dbl())))))

        # Constants and functions outside the grammar are rejected, with a pointer.
        err = try
            text2rulenode("```julia\nx + 3\n```", arith, :Start)
        catch e
            e
        end
        @test err isa GrammarParseError && err.kind == :grammar
        @test occursin("`3`", err.message) && occursin("Int", err.message)

        err = try
            text2rulenode("```julia\ninc(); triple()\n```", seq, :Start)
        catch e
            e
        end
        @test err isa GrammarParseError && occursin("triple()", err.message)

        err = try
            text2rulenode("```julia\nx + (\n```", arith, :Start)
        catch e
            e
        end
        @test err isa GrammarParseError && err.kind == :syntax
    end

    @testset "round trip on all small programs" begin
        for g in (arith, seq), p in Iterators.take(BFSIterator(g, :Start; max_depth = 4), 300)
            e = rulenode2expr(freeze_state(p), g)
            rn2, _ = text2rulenode("```julia\n" * LLM.rule_string(e) * "\n```", g, :Start)
            @test LLM.normalize_expr(rulenode2expr(rn2, g)) == LLM.normalize_expr(e)
        end
    end

    @testset "prompt is purely inductive" begin
        problem = Problem("secret_task_42",
            [IOExample(Dict{Symbol, Any}(:x => SeqDSL.Counter(1)), SeqDSL.Counter(4))])
        msgs = initial_messages(DEFAULT_PROMPT, seq, :Start, problem.spec)
        text = join([m.content for m in msgs], "\n")
        @test !occursin("secret_task_42", text)
        @test !occursin("SeqDSL", text)                 # no module names
        @test occursin("Counter(1)", text) && occursin("Counter(4)", text)
        @test occursin("Sequence = Operation | (Operation; Sequence)", text)
        @test format_value(SeqDSL.Counter(3)) == "Counter(3)"
        @test startswith(format_grammar(arith, :Start), "Start = Int\n")
    end

    @testset "llm_synth" begin
        problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), 2x + 1) for x in 1:4])
        interp = make_interpreter(arith; input_symbols = [:x],
            target_module = @__MODULE__, cache_module = @__MODULE__)

        # One-shot success.
        model, _ = scripted(["```julia\nx + x + 1\n```"])
        prog, log = llm_synth(arith, :Start, problem; model, interpret = interp)
        @test prog isa RuleNode
        @test all(interp(prog, ex) == ex.out for ex in problem.spec)
        @test log.solved && log.best_fitness == 1.0 && length(log.attempts) == 1

        # Repairs: grammar error, then wrong program, then correct.
        model, seen = scripted(["```julia\nx + 3\n```", "```julia\nx + 1\n```",
            "```julia\nx * 2 + 1\n```"])
        prog, log = llm_synth(arith, :Start, problem; model, interpret = interp, max_repairs = 2)
        @test log.solved && length(log.attempts) == 3
        @test length(seen[2]) == 4 && seen[2][end].role == "user"
        @test occursin("cannot be derived", seen[2][end].content)
        @test occursin("wrong on 4 of 4", seen[3][end].content)

        # No repairs, several samples: best (partial) program is returned.
        model, _ = scripted(["no code here", "```julia\nx\n```", "`(x == 1) ? 1 + 2 : x`"])
        prog, log = llm_synth(arith, :Start, problem; model, interpret = interp, num_samples = 3)
        @test !log.solved && length(log.attempts) == 3
        @test log.best_fitness == 0.25
        @test rulenode2expr(prog, arith) == rulenode2expr(log.attempts[3].program, arith)

        # Without an interpreter the first valid program is returned.
        model, _ = scripted(["```julia\nx + 7\n```", "```julia\nx + 2\n```"])
        prog, log = llm_synth(arith, :Start, problem; model, num_samples = 2)
        @test rulenode2expr(prog, arith) == :(x + 2)
        @test !log.solved && ismissing(log.best_fitness)

        # Nothing parseable at all.
        model, _ = scripted(["I don't know."])
        prog, log = llm_synth(arith, :Start, problem; model, interpret = interp)
        @test isnothing(prog)

        # Custom prompt and limited number of prompt examples.
        model, seen = scripted(["```julia\nx + x + 1\n```"])
        prompt = PromptTemplate(system = nothing,
            user = "G:\n{{grammar}}\nE:\n{{examples}}\nInputs: {{inputs}}")
        llm_synth(arith, :Start, problem; model, prompt, interpret = interp, prompt_examples = 2)
        @test length(seen[1]) == 1 && startswith(seen[1][1].content, "G:\n")
        @test occursin("Inputs: x", seen[1][1].content)
        @test occursin("Example 2", seen[1][1].content) && !occursin("Example 3", seen[1][1].content)

        @test_throws ArgumentError llm_synth(arith, :Nope, problem; model)
    end

    @testset "Ollama backend" begin
        @test LLM.OllamaModel("gpt-oss:20b"; think = "high").think == "high"
        @test LLM.OllamaModel("qwen3.5:4b"; host = "http://h:1").host == "http://h:1"
        @test any(m -> m.ollama == LLM.DEFAULT_OLLAMA_MODEL, LLM.RECOMMENDED_MODELS)
        # Unreachable server: the failure is recorded, not thrown.
        model = LLM.OllamaModel("m"; host = "http://127.0.0.1:9", timeout = 5)
        problem = Problem([IOExample(Dict{Symbol, Any}(:x => 1), 2)])
        prog, log = llm_synth(arith, :Start, problem; model)
        @test isnothing(prog) && !isnothing(log.attempts[1].error)
    end
end
