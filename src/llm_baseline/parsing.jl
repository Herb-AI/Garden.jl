#=
From model text to a `RuleNode`:

1. `extract_code` takes the program text out of the answer.
2. `parse_program` parses it with Julia's parser and normalises the syntax.
3. `expr2rulenode_typed` derives the expression from a nonterminal of the grammar
   by recursive descent over the productions.
=#

"""
    text2rulenode(text, grammar, start::Symbol) -> RuleNode

Turn a model answer into a derivation of `start` in `grammar`. Throws a
`GrammarParseError` if that is not possible.
"""
function text2rulenode(text::AbstractString, grammar::AbstractGrammar, start::Symbol)
    code = extract_code(text)
    isnothing(code) && throw(GrammarParseError("no program found in the answer"))
    return expr2rulenode_typed(parse_program(code, grammar), grammar, start)
end

"""
    extract_code(text) -> Union{String, Nothing}

Return the last fenced code block in `text` (also when its closing fence is
missing), else the last inline `` `code` `` span, else `nothing`. Reasoning
traces (`<think>…</think>`) are ignored.
"""
function extract_code(text::AbstractString)
    text = replace(text, r"<think>.*?(?:</think>|$)"s => "")
    blocks = collect(eachmatch(r"```[^\n]*\n(.*?)(?:```|$)"s, text))
    isempty(blocks) || return String(strip(blocks[end][1]))
    inline = collect(eachmatch(r"`([^`\n]+)`", text))
    isempty(inline) || return String(strip(inline[end][1]))
    return nothing
end

"""
    parse_program(code, grammar) -> Any

Parse `code` into a normalised Julia expression, removing wrappers that are not
part of the program: `function f(…) … end`, `return …` and `x = …` (unless the
grammar itself has assignments). Throws a `GrammarParseError` if the code does not
parse.
"""
function parse_program(code::AbstractString, grammar::AbstractGrammar)
    stmts = filter(a -> !(a isa LineNumberNode), Meta.parseall(code).args)
    for s in stmts
        if s isa Expr && s.head in (:error, :incomplete)
            detail = s.args[1] isa Exception ? sprint(showerror, s.args[1]) : string(s.args[1])
            throw(GrammarParseError(string("the code does not parse:\n", detail)))
        end
    end
    isempty(stmts) && throw(GrammarParseError("the code block is empty"))
    e = normalize_expr(length(stmts) == 1 ? only(stmts) : Expr(:block, stmts...))
    return _unwrap(e, any(r -> _contains_head(r, :(=)), _rules(grammar)))
end

function _unwrap(e, keep_assignments::Bool)
    e isa Expr || return e
    if e.head in (:function, :return) || (e.head == :(=) && !keep_assignments)
        return _unwrap(normalize_expr(e.args[end]), keep_assignments)
    end
    return e
end

_contains_head(e, head) = e isa Expr && (e.head == head || any(a -> _contains_head(a, head), e.args))

# ---------------------------------------------------------------------------
# Typed derivation
# ---------------------------------------------------------------------------

struct _Matcher{G <: AbstractGrammar}
    grammar::G
    patterns::Vector{Any}                 # the grammar's rules, normalised
    nonterminals::Set{Symbol}
    active::Set{Tuple{Any, Symbol}}       # derivations in progress (cycle guard)
    failures::Vector{Tuple{Any, Symbol}}  # for error messages
end

function _Matcher(grammar::AbstractGrammar)
    return _Matcher(
        grammar, Any[normalize_expr(r) for r in _rules(grammar)],
        Set{Symbol}(nonterminals(grammar)), Set{Tuple{Any, Symbol}}(), Tuple{Any, Symbol}[]
    )
end

"""
    expr2rulenode_typed(expr, grammar, type::Symbol) -> RuleNode

Derive the normalised expression `expr` from nonterminal `type` of `grammar`.
Productions are tried in grammar order and the first derivation found is
returned. Throws a `GrammarParseError` that points at the smallest offending
sub-expression if no derivation exists.
"""
function expr2rulenode_typed(expr, grammar::AbstractGrammar, type::Symbol)
    m = _Matcher(grammar)
    rn = _derive(m, expr, type)
    isnothing(rn) || return rn
    throw(GrammarParseError(_explain_failure(m, expr, type)))
end

# Derive `ex` from nonterminal `type`, or return `nothing`.
#
# There is no memoisation: a sub-expression is derived again for every production
# that reaches it. That is fast because model answers are small and productions of
# one nonterminal rarely share a top-level form, so most fail at their first
# symbol. A grammar with long chains of unit productions (`A = B`, `B = C`, …) or
# many productions of the same shape could make this exponential; if parsing ever
# gets slow, memoise `_derive` on `(ex, type)` first.
function _derive(m::_Matcher, ex, type::Symbol)
    key = (ex, type)
    key in m.active && return nothing  # cyclic unit productions such as `A = B`, `B = A`
    push!(m.active, key)
    result = nothing
    for r in _productions(m.grammar, type)
        children = AbstractRuleNode[]
        if _unify!(m, m.patterns[r], ex, children)
            result = RuleNode(r, children)
            break
        end
    end
    delete!(m.active, key)
    if isnothing(result) && !any(r -> _same_shape(m, m.patterns[r], ex), _productions(m.grammar, type))
        push!(m.failures, key)
    end
    return result
end

# Match production pattern `pat` against `ex`, collecting the derivations of the
# pattern's nonterminals in `children` (left to right, as `rulenode2expr` reads them).
function _unify!(m::_Matcher, pat, ex, children::Vector{AbstractRuleNode})
    if pat isa Symbol && pat in m.nonterminals
        child = _derive(m, ex, pat)
        isnothing(child) && return false
        push!(children, child)
        return true
    elseif pat isa Expr
        ex isa Expr || return false
        ex = _reassociate(pat, ex)
        pat.head == ex.head && length(pat.args) == length(ex.args) || return false
        return all(_unify!(m, p, e, children) for (p, e) in zip(pat.args, ex.args))
    else
        return _literal_equal(pat, ex)
    end
end

# Let flat forms written by the model match binary productions:
#   `a; b; c`   against `(A; B)`  →  `a; (b; c)`
#   `a + b + c` against `A + B`   →  `(a + b) + c`
function _reassociate(pat::Expr, ex::Expr)
    k = length(pat.args)
    if pat.head == :block && ex.head == :block && 2 <= k < length(ex.args)
        return Expr(:block, ex.args[1:(k - 1)]..., Expr(:block, ex.args[k:end]...))
    elseif pat.head == :call && ex.head == :call && k == 3 && length(ex.args) > 3 &&
            isequal(pat.args[1], ex.args[1])
        return Expr(:call, ex.args[1], Expr(:call, ex.args[1:(end - 1)]...), ex.args[end])
    end
    return ex
end

# Numbers compare by value (`1 == 0x01`), but `true` is not `1`.
function _literal_equal(p, e)
    p isa Number && e isa Number && return p == e && (p isa Bool) == (e isa Bool)
    return isequal(p, e)
end

# Could `pat` match `ex` at the top level, ignoring its children?
function _same_shape(m::_Matcher, pat, ex)
    pat isa Symbol && pat in m.nonterminals && return false  # unit production
    pat isa Expr || return _literal_equal(pat, ex)
    ex isa Expr && pat.head == ex.head || return false
    return pat.head != :call || isequal(pat.args[1], ex.args[1])
end

# Name the smallest sub-expression whose top-level form matches no production of
# the nonterminal it had to be derived from.
function _explain_failure(m::_Matcher, expr, type::Symbol)
    isempty(m.failures) && return "`$(_show_expr(expr))` cannot be derived from `$type`."
    ex, t = argmin(f -> length(_show_expr(f[1])), m.failures)
    prods = join(unique(rule_string(_rules(m.grammar)[r]) for r in _productions(m.grammar, t)), " | ")
    return "`$(_show_expr(ex))` cannot be derived from nonterminal `$t` " *
        "(its productions are: $t = $prods)."
end

_show_expr(e) = e isa Union{Expr, Symbol} ? rule_string(e) : repr(e)
