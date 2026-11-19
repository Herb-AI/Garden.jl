#=
Prompt construction. The default prompt is purely inductive: the model only sees
the grammar, its start symbol and the input/output examples. `initial_messages`
is never given the `Problem`, so its name cannot reach the prompt.
=#

"""
Abstract supertype of prompting strategies. A subtype implements

    initial_messages(prompt, grammar, start::Symbol, examples) -> Vector{ChatMessage}
    feedback_message(prompt, attempt::Attempt) -> String

`feedback_message` is only called when `max_repairs > 0` in [`llm_synth`](@ref).
"""
abstract type AbstractPrompt end

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
Grammar (start symbol: {{start}}):
```
{{grammar}}
```

Examples:
{{examples}}

Write a program in this grammar that is consistent with all examples."""

const DEFAULT_PARSE_FEEDBACK = """
Your answer could not be used: {{message}}

Reply with a corrected program in a single ```julia fenced code block."""

const DEFAULT_WRONG_FEEDBACK = """
Your program is derivable from the grammar, but it is wrong on these examples:
{{failures}}

Reply with a corrected program in a single ```julia fenced code block."""

"""
    PromptTemplate(; system, user, parse_feedback, wrong_feedback)

A prompt made of text templates with `{{placeholder}}` slots.

- `system`: system message, or `nothing` for none. Default `DEFAULT_SYSTEM_PROMPT`.
- `user`: first user message, with `{{grammar}}`, `{{start}}` and `{{examples}}`.
  Default `DEFAULT_USER_PROMPT`.
- `parse_feedback`: repair message when an answer could not be parsed into the
  grammar, with `{{message}}`. Default `DEFAULT_PARSE_FEEDBACK`.
- `wrong_feedback`: repair message when a program is wrong on some examples,
  with `{{failures}}`. Default `DEFAULT_WRONG_FEEDBACK`.
"""
Base.@kwdef struct PromptTemplate <: AbstractPrompt
    system::Union{Nothing, String} = DEFAULT_SYSTEM_PROMPT
    user::String = DEFAULT_USER_PROMPT
    parse_feedback::String = DEFAULT_PARSE_FEEDBACK
    wrong_feedback::String = DEFAULT_WRONG_FEEDBACK
end

"""
The default, purely inductive prompt.
"""
const DEFAULT_PROMPT = PromptTemplate()

function initial_messages(p::PromptTemplate, grammar::AbstractGrammar, start::Symbol, examples)
    values = Dict(
        "grammar" => format_grammar(grammar, start),
        "start" => string(start),
        "examples" => format_examples(examples)
    )
    messages = [ChatMessage("user", fill_template(p.user, values))]
    isnothing(p.system) || pushfirst!(messages, ChatMessage("system", fill_template(p.system, values)))
    return messages
end

function feedback_message(p::PromptTemplate, a::Attempt)
    isnothing(a.program) && return fill_template(p.parse_feedback, Dict("message" => a.error))
    return fill_template(p.wrong_feedback, Dict("failures" => format_failures(a.failures)))
end

"""
    fill_template(template, values::AbstractDict) -> String

Replace every `{{key}}` in `template` with `values[key]`; unknown keys are left
as they are.
"""
function fill_template(template::AbstractString, values::AbstractDict)
    return replace(template, r"\{\{(\w+)\}\}" => m -> string(get(values, m[3:(end - 2)], m)))
end

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

"""
    format_grammar(grammar, start) -> String

One line per nonterminal, `T = rhs₁ | rhs₂ | …`, starting with `start`.
Duplicate productions are shown once.
"""
function format_grammar(grammar::AbstractGrammar, start::Symbol)
    nonterminals = unique(vcat(start, grammar.types))
    lines = map(nonterminals) do nt
        rhss = unique(rule_string(grammar.rules[r]) for r in grammar.bytype[nt])
        string(nt, " = ", join(rhss, " | "))
    end
    return join(lines, "\n")
end

"""
    rule_string(rule) -> String

One-line rendering of a production's right-hand side, with blocks written
`(a; b)` and conditionals `(c ? a : b)`.
"""
rule_string(rule) = _rs(normalize_expr(rule))

function _rs(e)
    e isa Symbol && return string(e)
    e isa Expr || return repr(e)
    if e.head == :block
        return "(" * join(_rs.(e.args), "; ") * ")"
    elseif e.head == :if && length(e.args) == 3
        return "(" * _rs(e.args[1]) * " ? " * _rs(e.args[2]) * " : " * _rs(e.args[3]) * ")"
    elseif e.head == :call && any(a -> a isa Expr && a.head in (:block, :if), e.args[2:end])
        # A call whose arguments need the one-line forms above.
        f = e.args[1]
        if f isa Symbol && Base.isbinaryoperator(f) && length(e.args) == 3
            return _rs(e.args[2]) * " $f " * _rs(e.args[3])
        end
        return string(f) * "(" * join(_rs.(e.args[2:end]), ", ") * ")"
    end
    return string(e)
end

"""
    format_value(x) -> String

Print a value without the name of the module that defines its type, which could
reveal the benchmark.
"""
format_value(x) = sprint(show, x; context = :module => parentmodule(typeof(x)))

"""
    format_examples(examples) -> String

    Example 1:
      input _arg_1: "abc"
      output: "ABC"
"""
function format_examples(examples)
    blocks = map(enumerate(examples)) do (i, ex)
        lines = [[_labelled("input $k", v) for (k, v) in _inputs(ex)]; _labelled("output", ex.out)]
        "Example $i:\n  " * join(lines, "\n  ")
    end
    return join(blocks, "\n")
end

function format_failures(failures)
    blocks = map(failures) do (ex, actual)
        lines = [[_labelled("input $k", v) for (k, v) in _inputs(ex)];
                 _labelled("expected output", ex.out);
                 actual isa Exception ?
                     "your program raised: " * first(sprint(showerror, actual), 300) :
                     _labelled("your output", actual)]
        "- " * join(lines, "\n  ")
    end
    return join(blocks, "\n")
end

_inputs(ex) = sort!(collect(ex.in); by = string ∘ first)

# `label: value`, with a value that spans several lines (e.g. a grid) indented below the label.
function _labelled(label, value)
    s = format_value(value)
    occursin('\n', s) || return "$label: $s"
    return "$label:\n" * join(("    " * l for l in split(rstrip(s), '\n')), "\n")
end
