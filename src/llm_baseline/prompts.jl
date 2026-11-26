#=
Prompt construction: `PromptTemplate`, the default `AbstractPrompt`, and the
formatting helpers a custom prompt can reuse.

The default prompt is purely inductive: the model only sees the grammar, its
start symbol and the input/output examples. Two things guarantee it:
`initial_messages` is never given the `Problem`, and `format_value` removes the
module names of the values' types, which could reveal the benchmark.
=#

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
    return fill_template(p.wrong_feedback, Dict("failures" => format_failures(failures(a))))
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
    lines = map(unique(vcat(start, _nonterminals_in_order(grammar)))) do nt
        rhss = unique(rule_string(_rules(grammar)[r]) for r in _productions(grammar, nt))
        string(nt, " = ", join(rhss, " | "))
    end
    return join(lines, "\n")
end

"""
    format_value(x) -> String

Print a value without the names of the modules that define the types in it
(`HerbBenchmarks.String_transformations_2020.StringState("a", 1)` becomes
`StringState("a", 1)`), because a module name could reveal the benchmark. This
also covers types nested inside containers and struct fields.
"""
format_value(x) = _strip_module_names(sprint(show, x), _modules_in(x))

# Remove every suffix of each module's path, longest first, so that both
# `A.B.T` and `B.T` become `T` (Julia prints whichever is visible from `Main`).
function _strip_module_names(text::AbstractString, modules)
    for m in modules, i in eachindex(fullname(m))
        text = replace(text, join(fullname(m)[i:end], ".") * "." => "")
    end
    return text
end

# The modules of all non-Base types in `x`: its type and type parameters, and
# those of its elements and fields.
function _modules_in(x, found = Set{Module}())
    _type_modules!(found, typeof(x))
    if x isa Union{AbstractArray, Tuple, NamedTuple, AbstractSet}
        foreach(v -> _modules_in(v, found), x)
    elseif x isa AbstractDict
        foreach(kv -> (_modules_in(first(kv), found); _modules_in(last(kv), found)), x)
    elseif !_is_base(parentmodule(typeof(x)))
        for f in fieldnames(typeof(x))
            isdefined(x, f) && _modules_in(getfield(x, f), found)
        end
    end
    return found
end

function _type_modules!(found, T)
    T isa DataType || return found
    _is_base(parentmodule(T)) || push!(found, parentmodule(T))
    foreach(p -> _type_modules!(found, p), T.parameters)
    return found
end

_is_base(m::Module) = Base.moduleroot(m) in (Base, Core)

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

function format_failures(evaluations)
    blocks = map(evaluations) do e
        lines = [
            [_labelled("input $k", v) for (k, v) in _inputs(e.example)];
            _labelled("expected output", e.example.out);
            e.output isa Exception ?
                "your program raised: " * _error_line(e.output) :
                _labelled("your output", e.output)
        ]
        "- " * join(lines, "\n  ")
    end
    return join(blocks, "\n")
end

_inputs(ex) = sort!(collect(ex.in); by = string ∘ first)

# First line of an error message, without module names. Later lines (such as
# MethodError's "Closest candidates", with file paths) could reveal the benchmark.
_error_line(e) = _strip_module_names(first(split(sprint(showerror, e), '\n')), _modules_in(e))

# `label: value`, with a value that spans several lines (e.g. a grid) indented below the label.
function _labelled(label, value)
    s = format_value(value)
    occursin('\n', s) || return "$label: $s"
    return "$label:\n" * join(("    " * l for l in split(rstrip(s), '\n')), "\n")
end
