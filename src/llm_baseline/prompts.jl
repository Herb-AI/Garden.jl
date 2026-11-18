#=
Prompt construction.

The default prompt is *purely inductive*: the model only sees the grammar (with its
start symbol) and the input/output examples. No task name, identifier,
natural-language description or benchmark name is ever shown, and values are
printed without module qualification so that e.g.
`HerbBenchmarks.String_transformations_2020.StringState(...)` becomes
`StringState(...)`.

To customise prompting either
  * build a `PromptTemplate` with your own texts and/or formatting functions, or
  * define a new `AbstractPrompt` subtype and implement `initial_messages` and
    `feedback_message` for it.
=#

"""
Abstract supertype of prompting strategies. A subtype implements

    initial_messages(prompt, grammar, start::Symbol, examples) -> Vector{ChatMessage}
    feedback_message(prompt, grammar, start::Symbol, feedback::Feedback) -> String

`feedback_message` is only called when repair rounds are enabled
(`max_repairs > 0` in [`llm_synth`](@ref)).
"""
abstract type AbstractPrompt end

"""
    Feedback

What went wrong with a candidate, passed to [`feedback_message`](@ref).

- `kind`: `:no_program` (no code found in the answer), `:syntax` (code does not
  parse), `:grammar` (code is not derivable from the grammar) or `:wrong`
  (program derivable but incorrect on some examples).
- `program`: the candidate program text (may be empty).
- `message`: error message for the first three kinds.
- `failures`: for `:wrong`, a vector of `(example, actual)` pairs where `actual`
  is the produced output or the exception that was thrown.
- `num_examples`: number of examples the candidate was checked on.
"""
struct Feedback
    kind::Symbol
    program::String
    message::String
    failures::Vector{Tuple{Any, Any}}
    num_examples::Int
end

const DEFAULT_SYSTEM_PROMPT = """
You are an expert program synthesizer. You are given the grammar of a \
domain-specific language and input/output examples. Your task is to write one \
program, derivable from the grammar, that maps every example input to its \
example output.

Rules:
- The program must be derivable from the start symbol using only the \
productions of the grammar.
- Nonterminals are placeholders: replace each one with a sub-program derived from \
that nonterminal. Write every other symbol (function names, constants, input \
variables) exactly as it appears in the grammar.
- Functions, operators and constants that do not appear in the grammar are not \
allowed, and you cannot define helper functions or variables of your own.
- Write the program in the same concrete syntax as the productions.

Finish your answer with the program in a single ```julia fenced code block, \
with nothing after it."""

const DEFAULT_USER_PROMPT = """
Grammar (start symbol: {{start}}; nonterminals: {{nonterminals}}):
```
{{grammar}}
```

Examples ({{num_examples}}):
{{examples}}

Write a program in this grammar that is consistent with all examples."""

const DEFAULT_SYNTAX_FEEDBACK = """
Your answer did not contain a valid program: {{message}}

Reply with a corrected program in a single ```julia fenced code block."""

const DEFAULT_GRAMMAR_FEEDBACK = """
Your program cannot be derived from the grammar: {{message}}

Reply with a corrected program in a single ```julia fenced code block."""

const DEFAULT_WRONG_FEEDBACK = """
Your program is derivable from the grammar, but it is wrong on \
{{num_failed}} of {{num_examples}} examples:
{{failures}}

Reply with a corrected program in a single ```julia fenced code block."""

"""
    PromptTemplate(; kwargs...)

A prompt made of text templates with `{{placeholder}}` slots.

# Keyword arguments (all optional)
- `system`: system message (`nothing` to send none). Default:
  `DEFAULT_SYSTEM_PROMPT`.
- `user`: first user message. Default: `DEFAULT_USER_PROMPT`. Placeholders:
  `{{grammar}}`, `{{start}}`, `{{nonterminals}}`, `{{examples}}`,
  `{{num_examples}}`, `{{inputs}}`.
- `syntax_feedback`, `grammar_feedback`, `wrong_feedback`: repair messages.
  Placeholders: `{{program}}`, `{{message}}`, `{{failures}}`, `{{num_failed}}`,
  `{{num_examples}}`.
- `format_grammar(grammar, start) -> String`: default [`format_grammar`](@ref).
- `format_examples(examples) -> String`: default [`format_examples`](@ref).
- `format_value(x) -> String`: how a single input/output value is printed;
  default [`format_value`](@ref). Ignored if `format_examples` is replaced.

# Example
```julia
cot = PromptTemplate(user = DEFAULT_USER_PROMPT *
    "\\nFirst describe the transformation in words, then give the program.")
```
"""
Base.@kwdef struct PromptTemplate{FG, FE, FV} <: AbstractPrompt
    system::Union{Nothing, String} = DEFAULT_SYSTEM_PROMPT
    user::String = DEFAULT_USER_PROMPT
    syntax_feedback::String = DEFAULT_SYNTAX_FEEDBACK
    grammar_feedback::String = DEFAULT_GRAMMAR_FEEDBACK
    wrong_feedback::String = DEFAULT_WRONG_FEEDBACK
    format_grammar::FG = format_grammar
    format_value::FV = format_value
    format_examples::FE = nothing
end

_format_examples(p::PromptTemplate, examples) =
    isnothing(p.format_examples) ? format_examples(examples; format_value = p.format_value) :
    p.format_examples(examples)

function initial_messages(p::PromptTemplate, grammar::AbstractGrammar, start::Symbol, examples)
    inputs = sort!(unique!(reduce(vcat, [collect(keys(ex.in)) for ex in examples]; init = Symbol[])))
    values = Dict(
        "grammar" => p.format_grammar(grammar, start),
        "start" => string(start),
        "nonterminals" => join(_nonterminals(grammar, start), ", "),
        "examples" => _format_examples(p, examples),
        "num_examples" => string(length(examples)),
        "inputs" => join(string.(inputs), ", ")
    )
    messages = ChatMessage[]
    isnothing(p.system) || push!(messages, ChatMessage("system", fill_template(p.system, values)))
    push!(messages, ChatMessage("user", fill_template(p.user, values)))
    return messages
end

function feedback_message(p::PromptTemplate, ::AbstractGrammar, ::Symbol, fb::Feedback)
    values = Dict(
        "program" => fb.program,
        "message" => fb.message,
        "num_examples" => string(fb.num_examples),
        "num_failed" => string(length(fb.failures)),
        "failures" => _format_failures(p, fb.failures)
    )
    template = fb.kind == :wrong ? p.wrong_feedback :
        fb.kind == :grammar ? p.grammar_feedback : p.syntax_feedback
    return fill_template(template, values)
end

function _format_failures(p::PromptTemplate, failures)
    lines = String[]
    for (ex, actual) in failures
        push!(lines, "- input: " * _format_input(ex.in, p.format_value))
        push!(lines, "  expected output: " * _layout(p.format_value(ex.out)))
        if actual isa Exception
            push!(lines, "  your program raised: " * _short_error(actual))
        else
            push!(lines, "  your output: " * _layout(p.format_value(actual)))
        end
    end
    return replace(join(lines, "\n"), r" +\n" => "\n")
end

_short_error(e) = first(sprint(showerror, e), 300)

"""
    fill_template(template, values::AbstractDict) -> String

Replace every `{{key}}` in `template` with `values[key]`.
"""
function fill_template(template::AbstractString, values::AbstractDict)
    return replace(template, r"\{\{(\w+)\}\}" => m -> begin
        key = m[3:(end - 2)]
        haskey(values, key) ? string(values[key]) : m
    end)
end

# ---------------------------------------------------------------------------
# Grammar formatting
# ---------------------------------------------------------------------------

function _nonterminals(grammar::AbstractGrammar, start::Symbol)
    nts = unique(grammar.types)
    # Start symbol first, then in order of appearance.
    return vcat(filter(==(start), nts), filter(!=(start), nts))
end

"""
    format_grammar(grammar, start) -> String

Print `grammar` as one line per nonterminal, `T = rhs₁ | rhs₂ | …`, starting with
the productions of `start`. Duplicate productions are shown once and Julia blocks
are written inline as `(a; b)`.
"""
function format_grammar(grammar::AbstractGrammar, start::Symbol)
    lines = String[]
    for nt in _nonterminals(grammar, start)
        rhss = unique([rule_string(grammar.rules[i]) for i in eachindex(grammar.rules)
                       if grammar.types[i] == nt])
        push!(lines, string(nt, " = ", join(rhss, " | ")))
    end
    return join(lines, "\n")
end

"""
    rule_string(rule) -> String

Single-line rendering of a production's right-hand side.
"""
rule_string(rule) = _rs(_strip_lines(rule))

function _rs(e)
    e isa Symbol && return string(e)
    e isa Expr || return repr(e)
    if e.head == :block
        return "(" * join(_rs.(e.args), "; ") * ")"
    elseif e.head == :if && length(e.args) == 3
        return "(" * _rs(e.args[1]) * " ? " * _rs(e.args[2]) * " : " * _rs(e.args[3]) * ")"
    elseif e.head == :call && any(a -> a isa Expr && a.head in (:block, :if), e.args[2:end])
        f = e.args[1]
        if f isa Symbol && Base.isbinaryoperator(f) && length(e.args) == 3
            return _rs(e.args[2]) * " $f " * _rs(e.args[3])
        end
        return string(f) * "(" * join(_rs.(e.args[2:end]), ", ") * ")"
    else
        return string(e)
    end
end

_strip_lines(e) = e isa Expr ? Base.remove_linenums!(deepcopy(e)) : e

# ---------------------------------------------------------------------------
# Example formatting
# ---------------------------------------------------------------------------

"""
    format_value(x) -> String

Print a value compactly and without module prefixes (so the name of the module
that defines a type, which may reveal the benchmark, is not shown).
"""
function format_value(x)
    s = sprint(show, x; context = (:compact => false, :limit => false, :module => parentmodule(typeof(x))))
    # Remove any remaining module qualification such as `Foo.Bar.Baz(` -> `Baz(`.
    return replace(s, r"\b(?:[A-Za-z_]\w*\.)+(?=[A-Za-z_]\w*[({])" => "")
end

function _format_input(input::AbstractDict, fv)
    ks = sort!(collect(keys(input)); by = string)
    return join([string(k, " = ", _layout(fv(input[k]))) for k in ks], ", ")
end
_format_input(input, fv) = _layout(fv(input))

# Multi-line values (e.g. grids with a custom `show`) go on their own, indented lines.
function _layout(s::AbstractString)
    occursin('\n', s) || return String(s)
    lines = split(rstrip(s, '\n'), '\n')
    return "\n" * join(["    " * l for l in lines], "\n")
end

"""
    format_examples(examples; format_value = format_value) -> String

Default example layout:

    Example 1:
      input: _arg_1 = "abc"
      output: "ABC"
"""
function format_examples(examples; format_value = format_value)
    blocks = String[]
    for (i, ex) in enumerate(examples)
        push!(blocks, string(
            "Example ", i, ":\n",
            "  input: ", _format_input(ex.in, format_value), "\n",
            "  output: ", _layout(format_value(ex.out))
        ))
    end
    return replace(join(blocks, "\n"), r" +\n" => "\n")
end

"""
The default, purely inductive prompt.
"""
const DEFAULT_PROMPT = PromptTemplate()
