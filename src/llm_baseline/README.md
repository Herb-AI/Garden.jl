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
* **Pluggable models and prompts.** Any Ollama model, any OpenAI-compatible server
  (LM Studio, llama.cpp, MLX, vLLM, SGLang, hosted APIs) or a plain Julia function.
  Prompts are templates with `{{placeholders}}`, or your own `AbstractPrompt` type.
* **Optional sampling and repair.** You can draw `num_samples` independent answers,
  and give up to `max_repairs` rounds of feedback (the parse error, or the failing
  examples with the program's actual outputs). Feedback only uses the examples, so the
  setting stays inductive. The defaults (1 sample, 0 repairs) are a plain one-shot
  baseline.

## Installation

You need three things: Julia, a local model server, and a Julia environment with
Garden.jl and HerbBenchmarks.jl. The baseline's only extra dependencies (`JSON`
and the `Downloads` standard library) are installed with Garden.jl.

1. **Julia 1.10 or newer.** If you don't have it, install it with
   [juliaup](https://github.com/JuliaLang/juliaup):

   ```sh
   curl -fsSL https://install.julialang.org | sh
   ```

2. **A model server.** The defaults expect [Ollama](https://ollama.com): install the
   app (or `brew install ollama` / the Linux install script), which keeps the server
   running in the background, then pull a model and check it answers:

   ```sh
   ollama pull gpt-oss:20b        # ~14 GB download, needs ~16 GB of RAM/VRAM
   ollama run gpt-oss:20b "hi"
   ```

   Any OpenAI-compatible server works too (LM Studio, llama.cpp, MLX, vLLM). See
   [Using another backend or model](#using-another-backend-or-model).

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
using Garden.LLMBaseline: llm_synth, OllamaModel
import HerbBenchmarks.PBE_SLIA_Track_2019 as SLIA

pair = get_problem_grammar_pair(SLIA, "17212077")   # "01/15/2013" -> "01/2013", ...
interp = SLIA.make_SLIA_interpreter(pair.grammar)

program, log = llm_synth(pair.grammar, :Start, pair.problem;
    model = OllamaModel("gpt-oss:20b"; think = "medium"),
    interpret = interp, verbose = true)

println(log)        # LLMSynthLog(1 model calls, 1 valid programs, solved = true, ...)
isnothing(program) || println(rulenode2expr(program, pair.grammar))
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
using Garden.LLMBaseline: llm_synth, OllamaModel
import HerbBenchmarks.PBE_SLIA_Track_2019 as SLIA

model = OllamaModel("gpt-oss:20b"; think = "medium")
results = map(get_all_problem_grammar_pairs(SLIA)) do pair
    interp = SLIA.make_SLIA_interpreter(pair.grammar)
    program, log = llm_synth(pair.grammar, :Start, pair.problem; model, interpret = interp)
    (id = pair.identifier, solved = log.solved, fitness = log.best_fitness,
     program = isnothing(program) ? nothing : rulenode2expr(program, pair.grammar),
     seconds = log.seconds)
end
count(r -> r.solved, results) / length(results)
```

Interpreters for the other benchmarks:

| Benchmark | `interpret` |
|---|---|
| `PBE_SLIA_Track_2019` | `SLIA.make_SLIA_interpreter(pair.grammar)` |
| `DeepCoder_2016` | `DeepCoder_2016.make_deepcoder_interpreter(pair.grammar)` |
| `PBE_BV_Track_2018` | `PBE_BV_Track_2018.make_bv_interpreter(pair.grammar)` |
| `String_transformations_2020`, `Pixels_2020` | the module's `interpret` (stateful) |
| `Robots_2020` | `(p, ex) -> Robots_2020.interpret(p, ex.in[:_arg_1_])` (its inputs are stored under `:_arg_1_`, not `:_arg_1`) |

The interpreter is called as `interpret(program, example::IOExample)`. That is
the method the generated HerbInterpret interpreters provide, for both the
plain and the stateful kind. Pass `eq` if outputs need a custom comparison.

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

* Reasoning traces are long. `OllamaModel` defaults to `num_ctx = 32768`, because
  Ollama's own default context is much smaller and silently truncates. Raise
  `num_predict` / `num_ctx` if answers get cut off: an attempt that ends in
  `:no_program` usually means the model ran out of tokens while thinking.
* On Apple Silicon, MLX builds (e.g. `qwen3.8:27b-mlx`, or `mlx_lm.server` with an
  `mlx-community` model) are usually faster than GGUF.
* For `num_samples > 1`, set a non-zero `temperature` and a `seed`. Sample `i` uses
  `seed + i - 1`.

## Using another backend or model

```julia
using Garden.LLMBaseline: OllamaModel, OpenAICompatibleModel, FunctionModel

OllamaModel("qwen3.8:27b"; think = true, temperature = 0.6, num_ctx = 65536)

# LM Studio (default base_url), llama.cpp `llama-server`, `mlx_lm.server`, vLLM, ...
OpenAICompatibleModel("qwen/qwen3.8-27b"; base_url = "http://localhost:1234/v1")
OpenAICompatibleModel("gpt-oss-20b"; base_url = "http://localhost:8080/v1",
    extra = Dict("reasoning_effort" => "high"))

# Anything else: a function from chat messages to the answer text.
FunctionModel(messages -> my_inference(messages))
```

A new backend is a subtype of `AbstractLanguageModel` with one method:

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

# No system message, your own layout, your own value printer
prompt = PromptTemplate(system = nothing,
    user = "DSL:\n{{grammar}}\n\nI/O pairs:\n{{examples}}\n\nProgram:",
    format_value = x -> sprint(print, x))

llm_synth(grammar, :Start, problem; model, prompt)
```

Placeholders in `user`/`system`: `{{grammar}}`, `{{start}}`, `{{nonterminals}}`,
`{{examples}}`, `{{num_examples}}`, `{{inputs}}`. Placeholders in the feedback
templates (`syntax_feedback`, `grammar_feedback`, `wrong_feedback`):
`{{program}}`, `{{message}}`, `{{failures}}`, `{{num_failed}}`, `{{num_examples}}`.
You can also replace `format_grammar(grammar, start)` and `format_examples(examples)`.

To change the strategy itself (for example few-shot prompting or a two-stage
prompt), subtype `AbstractPrompt` and implement

```julia
initial_messages(prompt, grammar, start::Symbol, examples) -> Vector{ChatMessage}
feedback_message(prompt, grammar, start::Symbol, feedback::Feedback) -> String
```

What the default prompt shows: the grammar as one line per nonterminal
(`T = rhs₁ | rhs₂ | …`, with statement blocks written `(a; b)`), then the examples
as `input: _arg_1 = …` / `output: …`. Note that the grammar's own function names
(e.g. `makeUppercase()`) carry meaning. That is part of the grammar, not
information about the task.

## `llm_synth` options

| keyword | default | |
|---|---|---|
| `model` | `OllamaModel("gpt-oss:20b")` | the language model |
| `prompt` | `DEFAULT_PROMPT` | prompting strategy |
| `interpret` | `nothing` | `interpret(program, example)`; enables checking and ranking |
| `num_samples` | `1` | independent samples |
| `max_repairs` | `0` | feedback rounds per sample |
| `prompt_examples` | `nothing` (all) | show only the first *k* examples in the prompt; candidates are still checked on all examples |
| `eq` | `==` | output comparison |
| `allow_errors` | `true` | interpreter exceptions count as failed examples |
| `seed` | `nothing` | base sampling seed |
| `verbose` | `false` | `@info` every attempt |

Returns `(program, log)`: `program::Union{RuleNode, Nothing}`. The `log`
(`LLMSynthLog`) holds the first prompt, every `Attempt` (raw answer, extracted
code, parsed program, error, fitness, time), `solved`, `best_fitness` and the
total time.

## How the answer is parsed

* The program is taken from the last fenced code block of the answer (with
  fallbacks to an inline `` `code` `` span or the last line), after removing
  `<think>…</think>` traces.
* Harmless wrappers are removed: `function f(_arg_1) … end`, `f(_arg_1) = …`,
  `program = …` and `return …`. Assignments are kept if the grammar itself uses
  them, as in the ARC grammar.
* Equivalent surface syntax is accepted: `if … else … end` for `c ? a : b`;
  statement sequences on separate lines (or `a; b; c`) for right-nested
  `(Operation; Sequence)` productions; `f(a; b)` for `f((a; b))`; and `a + b + c`
  for binary `Int + Int`.
* Numbers must equal a constant in the grammar (`0x01` and `1` are the same
  number). Strings must match exactly.

The parser is available on its own: `text2rulenode(text, grammar, :Start)`, or
`expr2rulenode_typed(expr, grammar, :Start)` for an expression.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Request to … failed … Is the model server running?` | Start the Ollama app (or `ollama serve`), or check `host` / `base_url`. |
| `HTTP 404` mentioning the model | The model isn't pulled (`ollama pull <tag>`), or the tag is misspelled; `ollama list` shows what you have. |
| Attempts end in `no program found` | The model ran out of tokens while reasoning: raise `num_ctx` (e.g. `65536`) and/or `num_predict` on `OllamaModel`, or lower `think`. |
| Every attempt has fitness 0 on `Robots_2020` | Its inputs are stored under `:_arg_1_`; use `interpret = (p, ex) -> Robots_2020.interpret(p, ex.in[:_arg_1_])`. |
| Very slow | Use a mixture-of-experts model (`gpt-oss:20b`, `gemma4:26b`), the `-mlx` builds on Apple Silicon, or `think = "low"`. |

## Tests

The tests use scripted fake models, so they don't need a model server:

```sh
cd Garden.jl
julia --project -e 'using Pkg; Pkg.test()'
```

The first run takes several minutes, mostly because the package-wide JET lint
check compiles a lot.

### Live tests with a real model

`test/test_llm_baseline_live.jl` runs the baseline against a real model through
Ollama: a plain model call, an easy task the model is expected to solve (`x + 1`),
a harder task where only a valid program (or `nothing`) is required, a
statement-sequence DSL, and the OpenAI-compatible endpoint. These tests are
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
