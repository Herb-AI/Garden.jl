# LLM baseline

A language-model baseline for programming-by-example in Herb. Given a grammar and
a `Problem` (input/output examples), exactly as HerbBenchmarks.jl provides them, it
asks a (small, local) language model for a program and returns that program as a
`RuleNode` of the grammar.

```
grammar + examples ──► prompt ──► LLM ──► answer text
                                            │ extract last code block
                                            ▼
                         Julia expression ──► derivation from the start symbol ──► RuleNode
                                                                                     │ (optional)
                                                     interpret on all examples ◄─────┘
```

* **Grammar-faithful output.** The answer is parsed with Julia's parser and then
  *derived* from the start symbol by recursive descent over the productions. A
  returned `RuleNode` is therefore always a valid program of the grammar, and
  `rulenode2expr(program, grammar)` gives it back as an expression. Anything the
  grammar can't derive (a constant like `5` when only `0, 1, -1` exist, or an unknown
  function) is rejected, and the error names the offending sub-expression.
* **Purely inductive default prompt.** The model sees only the grammar (with its
  start symbol) and the examples: no problem name or identifier, no description, no
  benchmark name. Values are printed without module prefixes, so
  `HerbBenchmarks.String_transformations_2020.StringState(...)` is shown as
  `StringState(...)`.
* **Pluggable models and prompts.** Any model served by [Ollama](https://ollama.com),
  selected by its tag, or a plain Julia function (used by the tests).
  Prompts are templates with `{{placeholders}}`, or your own `AbstractPrompt` type.
* **Optional sampling and repair.** You can draw `num_samples` independent answers,
  and give up to `max_repairs` rounds of feedback (the parse error, or the failing
  examples with the program's actual outputs). Feedback only uses the examples, so the
  setting stays inductive. The defaults (1 sample, 0 repairs) are a plain one-shot
  baseline.

To understand or change the code, start with the [code reading guide](CODE_GUIDE.md).

## Installation

You need three things: Julia, Ollama, and a Julia environment with
Garden.jl and HerbBenchmarks.jl. The baseline's only extra dependencies (`JSON`
and the `Downloads` standard library) are installed with Garden.jl.

1. **Julia 1.10 or newer.** If you don't have it, install it with
   [juliaup](https://github.com/JuliaLang/juliaup):

   ```sh
   curl -fsSL https://install.julialang.org | sh
   ```

2. **Ollama.** Models are served by [Ollama](https://ollama.com): install the
   app (or `brew install ollama` / the Linux install script), which keeps the server
   running in the background, then pull a model and check it answers:

   ```sh
   ollama pull gpt-oss:20b        # ~14 GB download, needs ~16 GB of RAM/VRAM
   ollama run gpt-oss:20b "hi"
   ```

3. **A Julia environment** that uses Garden.jl (with this baseline) and
   HerbBenchmarks.jl. With local clones of both repositories next to each other:

   ```sh
   mkdir llm-experiments && cd llm-experiments
   julia --project=. -e 'using Pkg;
       Pkg.develop(path = "../Garden.jl");
       Pkg.develop(path = "../HerbBenchmarks.jl");
       Pkg.add("Herb")'
   ```

   Without local clones, `Pkg.add(url = "https://github.com/Herb-AI/Garden.jl")` and
   `Pkg.add(url = "https://github.com/Herb-AI/HerbBenchmarks.jl")` do the same
   (add `rev = "<branch>"` for an unreleased branch).

## Quick start

Save this as `run.jl` in your environment and run `julia --project=. run.jl`:

```julia
using Herb, HerbBenchmarks
using Garden.LLMBaseline: llm_synth, OllamaModel, fitness
import HerbBenchmarks.PBE_SLIA_Track_2019 as SLIA

pair = get_problem_grammar_pair(SLIA, "17212077")   # "01/15/2013" -> "01/2013", ...
interp = SLIA.make_SLIA_interpreter(pair.grammar)

program, attempts = llm_synth(pair.grammar, :Start, pair.problem;
    model = OllamaModel("gpt-oss:20b"; think = "medium"),
    interpret = interp)

isnothing(program) || println(rulenode2expr(program, pair.grammar))
fitness(attempts[end])   # 1.0 when the program solves all examples
```

The first run takes a minute or two to compile. After that, a problem takes from
seconds to a few minutes, depending on the model and how long it reasons.

`interpret` is optional. Without it, the first answer that is a valid program of
the grammar is returned, unchecked. With it, every candidate is run on all
examples, the first one that solves them all is returned, and otherwise the
candidate with the highest fitness is returned.

## Running a whole benchmark

```julia
using Herb, HerbBenchmarks, Garden
using Garden.LLMBaseline: llm_synth, OllamaModel, fitness
import HerbBenchmarks.PBE_SLIA_Track_2019 as SLIA

model = OllamaModel("gpt-oss:20b"; think = "medium")
results = map(get_all_problem_grammar_pairs(SLIA)) do pair
    interp = SLIA.make_SLIA_interpreter(pair.grammar)
    seconds = @elapsed program, attempts = llm_synth(pair.grammar, :Start, pair.problem;
        model, interpret = interp)
    (id = pair.identifier, solved = any(a -> fitness(a) === 1.0, attempts),
     program = isnothing(program) ? nothing : rulenode2expr(program, pair.grammar),
     seconds)
end
count(r -> r.solved, results) / length(results)
```

Interpreters for the other benchmarks:

| Benchmark | `interpret` |
|---|---|
| `PBE_SLIA_Track_2019` | `SLIA.make_SLIA_interpreter(pair.grammar)` |
| `DeepCoder_2016` | `DeepCoder_2016.make_deepcoder_interpreter(pair.grammar)` |
| `PBE_BV_Track_2018` | `PBE_BV_Track_2018.make_bv_interpreter(pair.grammar)` |
| `String_transformations_2020` | `(p, input) -> String_transformations_2020.interpret(p, input[:_arg_1])` |
| `Pixels_2020` | `(p, input) -> Pixels_2020.interpret(p, input[:_arg_1])` |
| `Robots_2020` | `(p, input) -> Robots_2020.interpret(p, input[:_arg_1_])` (its inputs are stored under `:_arg_1_`, not `:_arg_1`) |

The interpreter is called as `interpret(program, example.in)`, with the example's
input `Dict`: the same convention as Probe. Interpreters made by HerbInterpret's
`make_interpreter` take that directly. The stateful interpreters of the string,
pixel and robot benchmarks take the state itself, hence the one-line wrappers.
Pass `eq` if outputs need a custom comparison.

## Which model?

You don't have to support every model, so the presets focus on open-weight
models that fit a well-equipped laptop (roughly 16–32 GB of unified memory or
VRAM at 4-bit), as of November 2026. They are listed in
`LLMBaseline.RECOMMENDED_MODELS`:

| Model | Ollama tag | ≈ memory (Q4) | Notes |
|---|---|---|---|
| gpt-oss-20b | `gpt-oss:20b` | 16 GB | **Default.** 21B MoE, ~3.6B active, reasoning. Fast enough for whole benchmarks; strong on reasoning-heavy tasks. `think = "low" / "medium" / "high"`. |
| Qwen3.8-27B | `qwen3.8:27b` | 24 GB | Strongest dense model in this class (Aug 2026), hybrid thinking. Slower: use it for a "best local model" row. |
| Gemma 4 26B A4B | `gemma4:26b` | 20 GB | MoE (~3.8B active), reasoning; fast. |
| Gemma 4 31B | `gemma4:31b` | 24 GB | Dense; better than 26B A4B, slower. |
| Qwen3-Coder-30B-A3B | `qwen3-coder:30b` | 20 GB | Non-reasoning code model: a cheap "no thinking" baseline. |
| Qwen3.5-9B / 4B | `qwen3.5:9b`, `qwen3.5:4b` | 8 / 4 GB | Small-model baselines; reasoning is off by default on the small Qwen3.5 models, so set `think = true`. |

Why these:

* PBE is an *inductive reasoning* problem, and reasoning (thinking) models are
  consistently the strongest open models on PBE-style benchmarks (PBEBench reports
  gpt-oss-120b as the best open model; CodeARC finds the reasoning model o3-mini best
  among the 18 models it tests). So the list is mostly reasoning models.
  Off-the-shelf LLMs have also been reported to be weak at PBE on domains that are
  rare in their pretraining data (Li & Ellis, 2024). Expect DSLs like
  `String_transformations_2020` or `Robots_2020` to be much harder for them than
  SyGuS strings.
* Among models that fit a laptop, gpt-oss-20b is the usual 16 GB recommendation.
  Qwen3.8-27B and the Gemma 4 26B/31B models are the strongest 24–32 GB options on
  the current coding and reasoning benchmarks (vendor-reported numbers).
* No study has compared these exact models on HerbBenchmarks, so treat the ranking as
  a starting point. A run over one benchmark with 2–3 of the models above is cheap and
  settles it.

Practical tips:

* Reasoning traces are long. `OllamaModel` sets the `"num_ctx"` option to 32768,
  because Ollama's own default context is much smaller and silently truncates.
  Raise `"num_ctx"` / `"num_predict"` if answers get cut off: an attempt whose
  `error` is `no program found in the answer` usually means the model ran out of
  tokens while thinking.
* On Apple Silicon, the `-mlx` tags (e.g. `qwen3.8:27b-mlx`) are usually faster.
* For `num_samples > 1`, set a non-zero `"temperature"` and a `seed`. Sample `i`
  uses `seed + i - 1`.

## Using another model

Any model in the [Ollama library](https://ollama.com/library) works: pull it and
pass its tag.

```julia
using Garden.LLMBaseline: OllamaModel, FunctionModel

OllamaModel("qwen3.8:27b"; think = true, options = Dict("temperature" => 0.6, "num_ctx" => 65536))
OllamaModel("gpt-oss:20b"; think = "high", host = "http://other-machine:11434")

# A function from chat messages to the answer text (e.g. scripted answers in tests).
FunctionModel(messages -> "```julia\nx + 1\n```")
```

`OllamaModel` keywords: `host`, `think`, `options` and `timeout`. `options` takes
any Ollama option by its Ollama name, such as `"temperature"`, `"num_ctx"` or `"num_predict"`.

Other model servers are not supported yet. A new backend is a subtype of
`AbstractLanguageModel` with one method:

```julia
struct MyModel <: LLMBaseline.AbstractLanguageModel end
LLMBaseline.generate(m::MyModel, messages::Vector{LLMBaseline.ChatMessage}; seed = nothing) = "..."
```

## Changing the prompt

The default prompt is `DEFAULT_PROMPT = PromptTemplate()`; its texts are
`DEFAULT_SYSTEM_PROMPT` and `DEFAULT_USER_PROMPT`. Override any part:

```julia
using Garden.LLMBaseline: PromptTemplate, DEFAULT_USER_PROMPT

# Different wording / an explicit chain-of-thought request
prompt = PromptTemplate(user = DEFAULT_USER_PROMPT *
    "\nFirst explain the transformation in one sentence, then give the program.")

# No system message and your own layout
prompt = PromptTemplate(system = nothing,
    user = "DSL:\n{{grammar}}\n\nI/O pairs:\n{{examples}}\n\nProgram:")

llm_synth(grammar, :Start, problem; model, prompt)
```

Placeholders in `user`/`system`: `{{grammar}}`, `{{start}}`, `{{examples}}`. The
feedback templates are `parse_feedback` (for an answer that could not be parsed
into the grammar, with `{{message}}`) and `wrong_feedback` (for a program that is
wrong on some examples, with `{{failures}}`).

To change anything else, such as how values are printed, few-shot prompting or a
two-stage prompt, subtype `AbstractPrompt` and implement

```julia
initial_messages(prompt, grammar, start::Symbol, examples) -> Vector{ChatMessage}
feedback_message(prompt, attempt::Attempt) -> String
```

The helpers `format_grammar`, `format_examples`, `format_value` and `fill_template`
are there to reuse, and an `Attempt` carries everything about the failed answer
(its `error`, or its `evaluations`; `failures(attempt)` gives the wrong ones). The `TersePrompt` in
`test/test_llm_baseline.jl` is a complete example in eight lines.

What the default prompt shows: the grammar as one line per nonterminal
(`T = rhs₁ | rhs₂ | …`, with statement blocks written `(a; b)`), then the examples
as `input _arg_1: …` / `output: …`. Note that the grammar's own function names
(e.g. `makeUppercase()`) carry meaning. That is part of the grammar, not
information about the task.

## `llm_synth` options

| keyword | default | |
|---|---|---|
| `model` | `OllamaModel("gpt-oss:20b")` | the language model |
| `prompt` | `DEFAULT_PROMPT` | prompting strategy |
| `interpret` | `nothing` | `interpret(program, example.in)`, as in Probe; enables checking and ranking |
| `num_samples` | `1` | independent samples |
| `max_repairs` | `0` | feedback rounds per sample |
| `eq` | `==` | output comparison |
| `seed` | `nothing` | base sampling seed |

Returns `(program, attempts)`: `program::Union{RuleNode, Nothing}` and one
`Attempt` per model call, with the full answer, the extracted code, the parsed
program or the reason it could not be parsed, its `evaluations` (the program's
output on every example, and whether it was correct),
and the time taken. Interpreter exceptions count as failed examples. If Ollama
cannot be reached, `llm_synth` throws.

To log every attempt, run with `JULIA_DEBUG=Garden`.

## How the answer is parsed

* The program is taken from the last fenced code block of the answer (also when
  the closing fence is missing), or else from the last inline `` `code` `` span,
  after removing `<think>…</think>` traces.
* Harmless wrappers are removed: `function f(_arg_1) … end`, `f(_arg_1) = …`,
  `program = …` and `return …`. Assignments are kept if the grammar itself uses
  them, as in the ARC grammar.
* Equivalent surface syntax is accepted: `if … else … end` for `c ? a : b`;
  statement sequences on separate lines (or `a; b; c`) for right-nested
  `(Operation; Sequence)` productions; and `a + b + c` for binary `Int + Int`.
* Numbers must equal a constant in the grammar (`0x01` and `1` are the same
  number). Strings must match exactly.

The parser is available on its own: `text2rulenode(text, grammar, :Start)`, or
`expr2rulenode_typed(expr, grammar, :Start)` for an expression.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Request to … failed … Is Ollama running?` | Start the Ollama app (or `ollama serve`), or check `host`. |
| `HTTP 404` mentioning the model | The model isn't pulled (`ollama pull <tag>`), or the tag is misspelled; `ollama list` shows what you have. |
| Attempts end in `no program found` | The model ran out of tokens while reasoning: raise `"num_ctx"` (e.g. `65536`) and/or `"num_predict"` in `OllamaModel`'s `options`, or lower `think`. |
| Every attempt has fitness 0, and the outputs in `attempts[1].evaluations` are `KeyError`s or `MethodError`s | The interpreter does not take the input `Dict`: wrap it, e.g. `(p, input) -> Robots_2020.interpret(p, input[:_arg_1_])` (see the interpreter table above). |
| Very slow | Use a mixture-of-experts model (`gpt-oss:20b`, `gemma4:26b`), the `-mlx` builds on Apple Silicon, or `think = "low"`. |

## Tests

The tests use scripted fake models, so they don't need Ollama:

```sh
cd Garden.jl
julia --project -e 'using Pkg; Pkg.test()'
```

The first run takes several minutes, mostly because the package-wide JET lint
check compiles a lot.

### Live tests with a real model

`test/test_llm_baseline_live.jl` runs the baseline against a real model through
Ollama: a plain model call, an easy task the model is expected to solve (`x + 1`),
a harder task where only a valid program (or `nothing`) is required, and a
statement-sequence DSL. These tests are
**disabled by default**; when disabled they are skipped with a log message. Enable
them with an environment variable:

```sh
ollama pull qwen3.5:4b
GARDEN_LLM_TESTS=true julia --project -e 'using Pkg; Pkg.test()'
```

| Variable | Default | |
|---|---|---|
| `GARDEN_LLM_TESTS` | `false` | `true`, `1` or `yes` enables the live tests |
| `GARDEN_LLM_MODEL` | `qwen3.5:4b` | Ollama tag of the model to test with |
| `GARDEN_LLM_HOST` | `http://localhost:11434` | Ollama server |

Model answers vary from run to run, so a failure of the "solves `x + 1`" test with a
small model can be bad luck rather than a bug. Look at the logged attempts before
investigating.

### Benchmark tests

`test/test_llm_baseline_benchmarks.jl` checks the baseline against every benchmark
in HerbBenchmarks.jl, without a model: random programs from each grammar must print
and parse back to themselves, no prompt or feedback message may contain a module
name or problem name, and each benchmark's interpreter must work with the
`interpret(program, input)` convention. Run it after changing the parser, the
prompt formatting or the interpreter table above.

HerbBenchmarks is not a registered package, so these tests run from the
environment of the installation section rather than through `Pkg.test()`. They are
disabled by default:

```sh
GARDEN_BENCHMARK_TESTS=true julia --project=llm-experiments Garden.jl/test/test_llm_baseline_benchmarks.jl
```
