using Test

import RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

import Garden.LLMBaseline as LLM
import Garden.LLMBaseline: llm_synth, FunctionModel, ChatMessage, PromptTemplate,
    AbstractPrompt, Attempt, Evaluation, GrammarParseError, text2rulenode, extract_code,
    evaluate, fitness, failures,
    format_grammar, format_examples, format_value, initial_messages, feedback_message,
    DEFAULT_PROMPT
import Herb: HerbCore, @csgrammar, BFSIterator, IOExample, Problem, RuleNode, freeze_state,
    make_interpreter, rulenode2expr

# Primitives of a tiny sequence DSL used below.
module SeqDSL
    struct Counter
        n::Int
    end
    inc(c::Counter) = Counter(c.n + 1)
    dbl(c::Counter) = Counter(2c.n)
    struct Pair2
        a::Counter
        b::Counter
    end
end

# The smallest custom prompting strategy: one user message, terse feedback.
struct TersePrompt <: AbstractPrompt end
function LLM.initial_messages(::TersePrompt, grammar, start, examples)
    return [ChatMessage("user", format_grammar(grammar, start) * "\n" * format_examples(examples))]
end
LLM.feedback_message(::TersePrompt, a::Attempt) =
    isnothing(a.program) ? "Parse error: $(a.error)" : "Wrong on $(length(failures(a))) examples."

# Answers scripted replies in order and records every conversation it sees.
function scripted(replies)
    seen = Vector{Vector{ChatMessage}}()
    i = Ref(0)
    model = FunctionModel(
        messages -> begin
            push!(seen, copy(messages))
            i[] += 1
            replies[min(i[], length(replies))]
        end
    )
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
        @test isnothing(extract_code("no code here"))
    end

    @testset "parsing into the grammar" begin
        rn = text2rulenode("```julia\nx + 1 + 2\n```", arith, :Start)
        @test rulenode2expr(rn, arith) == :((x + 1) + 2)

        rn = text2rulenode("```julia\nif x == 1\n  2\nelse\n  x * x\nend\n```", arith, :Start)
        @test rulenode2expr(rn, arith) == rulenode2expr(
            text2rulenode("`(x == 1) ? 2 : x * x`", arith, :Start), arith
        )

        rn = text2rulenode("```julia\nfunction f(x)\n  return x * 2\nend\n```", arith, :Start)
        @test rulenode2expr(rn, arith) == :(x * 2)

        # Flat statement sequences are re-nested to match `(Operation; Sequence)`.
        rn = text2rulenode("```julia\ninc()\ndbl()\nREPEAT((inc(); dbl()))\n```", seq, :Start)
        expr = rulenode2expr(rn, seq)
        @test LLM.normalize_expr(expr) ==
            LLM.normalize_expr(:(inc(); (dbl(); REPEAT((inc(); dbl())))))

        rn = text2rulenode("`inc(); dbl()`", seq, :Start)  # one line: Julia parses it as `:toplevel`
        @test LLM.normalize_expr(rulenode2expr(rn, seq)) == LLM.normalize_expr(:(inc(); dbl()))

        # Constants and functions outside the grammar are rejected, with a pointer.
        err = try
            text2rulenode("```julia\nx + 3\n```", arith, :Start)
        catch e
            e
        end
        @test err isa GrammarParseError
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
        @test err isa GrammarParseError && occursin("does not parse", err.message)
    end

    @testset "round trip on all small programs" begin
        # A conditional inside a sum forces the one-line printer; nesting must survive.
        e = :((x == 1 ? 1 : 2) + (x + 1))
        rn = text2rulenode("`" * LLM.rule_string(e) * "`", arith, :Start)
        @test LLM.normalize_expr(rulenode2expr(rn, arith)) == LLM.normalize_expr(e)

        for g in (arith, seq), p in Iterators.take(BFSIterator(g, :Start; max_depth = 4), 300)
            e = rulenode2expr(freeze_state(p), g)
            rn2 = text2rulenode("```julia\n" * LLM.rule_string(e) * "\n```", g, :Start)
            @test LLM.normalize_expr(rulenode2expr(rn2, g)) == LLM.normalize_expr(e)
        end
    end

    @testset "prompt is purely inductive" begin
        problem = Problem(
            "secret_task_42",
            [IOExample(Dict{Symbol, Any}(:x => SeqDSL.Counter(1)), SeqDSL.Counter(4))]
        )
        msgs = initial_messages(DEFAULT_PROMPT, seq, :Start, problem.spec)
        text = join([m.content for m in msgs], "\n")
        @test !occursin("secret_task_42", text)
        @test !occursin("SeqDSL", text)                 # no module names
        @test occursin("Counter(1)", text) && occursin("Counter(4)", text)
        @test occursin("Sequence = Operation | (Operation; Sequence)", text)
        @test format_value(SeqDSL.Counter(3)) == "Counter(3)"
        @test format_value("call os.path(x)") == "\"call os.path(x)\""   # strings untouched
        # Module names are removed from nested types too.
        c = SeqDSL.Counter(1)
        for v in ([c, c], (c, 1), Dict(:k => c), SeqDSL.Pair2(c, c), Any[c])
            @test !occursin("SeqDSL", format_value(v))
        end
        # ... and from error messages shown as feedback.
        err = try
            SeqDSL.inc(1)
        catch e
            e
        end
        failure = Evaluation(IOExample(Dict{Symbol, Any}(:x => 1), 2), err, false)
        attempt = Attempt(1, 0, "", "", RuleNode(1), nothing, [failure], 0.0)
        msg = feedback_message(DEFAULT_PROMPT, attempt)
        @test occursin("your program raised: MethodError", msg) && !occursin("SeqDSL", msg)
        @test startswith(format_grammar(arith, :Start), "Start = Int\n")
    end

    @testset "llm_synth" begin
        problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), 2x + 1) for x in 1:4])
        interp = make_interpreter(
            arith; input_symbols = [:x],
            target_module = @__MODULE__, cache_module = @__MODULE__
        )

        # One-shot success.
        model, _ = scripted(["```julia\nx + x + 1\n```"])
        prog, attempts = llm_synth(arith, :Start, problem; model, interpret = interp)
        @test prog isa RuleNode
        @test all(interp(prog, ex.in) == ex.out for ex in problem.spec)
        @test length(attempts) == 1 && fitness(attempts[1]) == 1.0
        @test length(attempts[1].evaluations) == 4 && isempty(failures(attempts[1]))

        # Repairs: grammar error, then wrong program, then correct.
        model, seen = scripted(
            [
                "```julia\nx + 3\n```", "```julia\nx + 1\n```",
                "```julia\nx * 2 + 1\n```",
            ]
        )
        prog, attempts = llm_synth(arith, :Start, problem; model, interpret = interp, max_repairs = 2)
        @test length(attempts) == 3 && fitness(attempts[3]) == 1.0
        @test length(seen[2]) == 4 && seen[2][end].role == "user"
        @test occursin("cannot be derived", seen[2][end].content)
        @test occursin("wrong on these examples", seen[3][end].content)
        @test count("expected output", seen[3][end].content) == 4

        # No repairs, several samples: best (partial) program is returned.
        model, _ = scripted(["no code here", "```julia\nx\n```", "`(x == 1) ? 1 + 2 : x`"])
        prog, attempts = llm_synth(arith, :Start, problem; model, interpret = interp, num_samples = 3)
        @test length(attempts) == 3 && isnothing(attempts[1].program)
        @test fitness(attempts[3]) == 0.25
        # Every output is kept, also on the examples the program gets right.
        @test [e.output for e in attempts[3].evaluations] == [3, 2, 3, 4]
        @test [e.correct for e in attempts[3].evaluations] == [true, false, false, false]
        @test [e.example.in[:x] for e in failures(attempts[3])] == [2, 3, 4]
        @test rulenode2expr(prog, arith) == rulenode2expr(attempts[3].program, arith)

        # Without an interpreter the first valid program is returned.
        model, _ = scripted(["```julia\nx + 7\n```", "```julia\nx + 2\n```"])
        prog, attempts = llm_synth(arith, :Start, problem; model, num_samples = 2)
        @test rulenode2expr(prog, arith) == :(x + 2)
        @test ismissing(fitness(attempts[2])) && isnothing(attempts[2].evaluations)
        @test isempty(failures(attempts[2]))

        # Nothing parseable at all.
        model, _ = scripted(["I don't know."])
        prog, attempts = llm_synth(arith, :Start, problem; model, interpret = interp)
        @test isnothing(prog) && attempts[1].error == "no program found in the answer"

        # Custom prompt.
        model, seen = scripted(["```julia\nx + x + 1\n```"])
        prompt = PromptTemplate(system = nothing, user = "G:\n{{grammar}}\nE:\n{{examples}}")
        llm_synth(arith, :Start, problem; model, prompt, interpret = interp)
        @test length(seen[1]) == 1 && startswith(seen[1][1].content, "G:\nStart = Int")
        @test occursin("Example 4:\n  input x: 4\n  output: 9", seen[1][1].content)

        @test_throws ArgumentError llm_synth(arith, :Nope, problem; model)
    end

    @testset "custom prompt type" begin
        problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), 2x + 1) for x in 1:4])
        interp = make_interpreter(
            arith; input_symbols = [:x],
            target_module = @__MODULE__, cache_module = @__MODULE__
        )
        model, seen = scripted(["`x + 3`", "`x + 1`", "`x + x + 1`"])
        prog, attempts = llm_synth(
            arith, :Start, problem; model, prompt = TersePrompt(),
            interpret = interp, max_repairs = 2
        )
        @test rulenode2expr(prog, arith) == :((x + x) + 1)
        @test length(seen[1]) == 1 && startswith(seen[1][1].content, "Start = Int")
        @test startswith(seen[2][end].content, "Parse error: `3` cannot be derived")
        @test seen[3][end].content == "Wrong on 4 examples."
    end

    @testset "Ollama backend" begin
        @test LLM.OllamaModel("gpt-oss:20b"; think = "high").think == "high"
        @test LLM.OllamaModel("qwen3.5:4b"; host = "http://h:1").host == "http://h:1"
        @test any(m -> m.ollama == LLM.DEFAULT_OLLAMA_MODEL, LLM.RECOMMENDED_MODELS)
        # Unreachable server: a clear error, not a silent failure.
        model = LLM.OllamaModel("m"; host = "http://127.0.0.1:9", timeout = 5)
        problem = Problem([IOExample(Dict{Symbol, Any}(:x => 1), 2)])
        @test_throws "Is Ollama running?" llm_synth(arith, :Start, problem; model)
    end
end
