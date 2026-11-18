#=
From model text to a `RuleNode`.

1. `extract_code` pulls the program text out of the answer (last fenced block).
2. `parse_program` parses it with Julia's parser and normalises the syntax
   (line numbers, single-statement blocks, `if … end` vs. ternaries, wrappers
   such as `function f(_arg_1) … end` or `return …`).
3. `expr2rulenode_typed` derives the expression from a nonterminal of the
   grammar by recursive descent over the productions, returning the derivation
   as a `RuleNode`. It is stricter and more general than
   `HerbGrammar.expr2rulenode`: it is type-directed, handles arbitrary
   production shapes (blocks, infix operators, conditionals, nested calls,
   literal constants) and reports *where* a program leaves the grammar.
=#

"""
    GrammarParseError(message)

Thrown when model output cannot be turned into a program of the grammar.
`kind` is `:no_program`, `:syntax` or `:grammar`.
"""
struct GrammarParseError <: Exception
    kind::Symbol
    message::String
end
Base.showerror(io::IO, e::GrammarParseError) = print(io, e.message)

"""
    extract_code(text) -> Union{String, Nothing}

Return the contents of the last fenced code block in `text`. If there is none,
fall back to the last inline `` `code` `` span, and finally to the last
non-empty line. Returns `nothing` for empty answers.
"""
function extract_code(text::AbstractString)
    text = strip_reasoning(text)
    isempty(text) && return nothing
    blocks = collect(eachmatch(r"```[ \t]*[\w+-]*[ \t]*\r?\n(.*?)```"s, text))
    isempty(blocks) || return String(strip(something(blocks[end][1], "")))
    # Unterminated final block (answer cut off): take what is there.
    m = match(r"```[ \t]*[\w+-]*[ \t]*\r?\n(.*)$"s, text)
    isnothing(m) || return String(strip(something(m[1], "")))
    inline = collect(eachmatch(r"`([^`\n]+)`", text))
    isempty(inline) || return String(strip(something(inline[end][1], "")))
    lines = filter(!isempty, strip.(split(text, '\n')))
    return isempty(lines) ? nothing : String(lines[end])
end

"""
    parse_program(code, grammar) -> Any

Parse `code` into a normalised Julia expression. Throws a `GrammarParseError` of
kind `:syntax` if the code does not parse.
"""
function parse_program(code::AbstractString, grammar::AbstractGrammar)
    parsed = try
        Meta.parseall(code)
    catch e
        throw(GrammarParseError(:syntax, string("the code does not parse:\n", sprint(showerror, e))))
    end
    stmts = filter(a -> !(a isa LineNumberNode), parsed.args)
    for s in stmts
        if s isa Expr && s.head in (:error, :incomplete)
            detail::String = isempty(s.args) ? "" :
                s.args[1] isa Exception ? sprint(showerror, s.args[1]) : string(s.args[1])
            throw(GrammarParseError(:syntax, string("the code does not parse:\n", detail)))
        end
    end
    isempty(stmts) && throw(GrammarParseError(:no_program, "the code block is empty"))
    expr = length(stmts) == 1 ? stmts[1] : Expr(:block, stmts...)
    return _unwrap_program(normalize_expr(expr), grammar)
end

# Remove wrappers that are not part of the DSL program itself.
function _unwrap_program(e, grammar)
    allows_assign = _grammar_has_head(grammar, :(=))
    while e isa Expr
        if e.head == :function && length(e.args) == 2
            e = e.args[2]
        elseif e.head == :(=) && !allows_assign && length(e.args) == 2
            e = e.args[2]          # `program = …`, `f(_arg_1) = …`
        elseif e.head == :return && length(e.args) == 1
            e = e.args[1]
        else
            break
        end
        e = normalize_expr(e)
    end
    return e
end

function _grammar_has_head(grammar, head::Symbol)
    found = Ref(false)
    walk(e) = if e isa Expr
        e.head == head && (found[] = true)
        foreach(walk, e.args)
    end
    foreach(walk, grammar.rules)
    return found[]
end

"""
    normalize_expr(e)

Canonical form used on both sides of the matching: no line numbers, no
single-statement blocks, `elseif` → `if`, and `return x` → `x` inside blocks.
"""
function normalize_expr(e)
    e isa LineNumberNode && return nothing
    e isa QuoteNode && return e
    e isa Expr || return e
    args = Any[]
    for a in e.args
        a isa LineNumberNode && continue
        push!(args, normalize_expr(a))
    end
    head = e.head == :elseif ? :if : e.head
    if head == :call
        args = _parameters_to_block(args)
    end
    if head == :block || head == :toplevel
        length(args) == 1 && return args[1]
        return Expr(:block, args...)
    end
    return Expr(head, args...)
end

# `f(a; b)` is keyword syntax in Julia, but when a model writes it, it means a
# statement sequence as the last argument: `f((a; b))`.
function _parameters_to_block(args::Vector{Any})
    i = findfirst(a -> a isa Expr && a.head == :parameters, args)
    (isnothing(i) || length(args) < 3) && return args
    params = args[i].args
    rest = Any[a for (j, a) in enumerate(args) if j != i]
    rest[end] = Expr(:block, rest[end], params...)
    return rest
end

# ---------------------------------------------------------------------------
# Typed derivation
# ---------------------------------------------------------------------------

struct _Matcher{G <: AbstractGrammar}
    grammar::G
    patterns::Vector{Any}
    nonterminals::Set{Symbol}
    memo::Dict{Tuple{Any, Symbol}, Union{Nothing, RuleNode}}
    active::Set{Tuple{Any, Symbol}}
    failures::Vector{Tuple{Any, Symbol}}
end

function _Matcher(grammar::AbstractGrammar)
    return _Matcher(
        grammar,
        Any[normalize_expr(r) for r in grammar.rules],
        Set{Symbol}(grammar.types),
        Dict{Tuple{Any, Symbol}, Union{Nothing, RuleNode}}(),
        Set{Tuple{Any, Symbol}}(),
        Tuple{Any, Symbol}[]
    )
end

"""
    expr2rulenode_typed(expr, grammar, type::Symbol) -> RuleNode

Derive the (already normalised) expression `expr` from nonterminal `type` of
`grammar`. Productions are tried in grammar order and the first derivation found
is returned. Throws a `GrammarParseError` of kind `:grammar` that points at the
smallest offending sub-expression if no derivation exists.
"""
function expr2rulenode_typed(expr, grammar::AbstractGrammar, type::Symbol)
    type in grammar.types || throw(ArgumentError("`$type` is not a nonterminal of the grammar"))
    m = _Matcher(grammar)
    rn = _derive(m, expr, type)
    isnothing(rn) || return rn
    throw(GrammarParseError(:grammar, _explain_failure(m, expr, type)))
end

function _derive(m::_Matcher, ex, type::Symbol)
    key = (ex, type)
    haskey(m.memo, key) && return m.memo[key]
    key in m.active && return nothing          # cyclic unit productions
    push!(m.active, key)
    result = nothing
    shape_ok = false
    for r in m.grammar.bytype[type]
        pat = m.patterns[r]
        shape_ok |= _same_shape(m, pat, ex)
        children = AbstractRuleNode[]
        if _unify!(m, pat, ex, children)
            result = isempty(children) ? RuleNode(r) : RuleNode(r, children)
            break
        end
    end
    delete!(m.active, key)
    if isnothing(result) && !shape_ok
        push!(m.failures, key)
    end
    m.memo[key] = result
    return result
end

# Can `pat` at the top level match `ex` at all (ignoring children)?
function _same_shape(m::_Matcher, pat, ex)
    pat isa Symbol && pat in m.nonterminals && return false  # unit production
    pat isa Expr || return _literal_equal(pat, ex)
    ex isa Expr || return false
    pat.head == ex.head || return false
    if pat.head == :call
        return !isempty(ex.args) && isequal(pat.args[1], ex.args[1])
    end
    return true
end

function _unify!(m::_Matcher, pat, ex, children::Vector{AbstractRuleNode})
    if pat isa Symbol && pat in m.nonterminals
        child = _derive(m, ex, pat)
        isnothing(child) && return false
        push!(children, child)
        return true
    elseif pat isa Expr
        ex isa Expr || return false
        ex = _reassociate(pat, ex)
        pat.head == ex.head || return false
        length(pat.args) == length(ex.args) || return false
        for (p, e) in zip(pat.args, ex.args)
            _unify!(m, p, e, children) || return false
        end
        return true
    else
        return _literal_equal(pat, ex)
    end
end

# Let flat forms written by the model match binary productions:
#   `a; b; c`   against `(A; B)`   → `a; (b; c)`
#   `a + b + c` against `A + B`    → `(a + b) + c`
function _reassociate(pat::Expr, ex::Expr)
    k = length(pat.args)
    if pat.head == :block && ex.head == :block && 2 <= k < length(ex.args)
        return Expr(:block, ex.args[1:(k - 1)]..., Expr(:block, ex.args[k:end]...))
    end
    if pat.head == :call && ex.head == :call && k == 3 && length(ex.args) > 3 &&
            isequal(pat.args[1], ex.args[1])
        return Expr(:call, ex.args[1], Expr(:call, ex.args[1:(end - 1)]...), ex.args[end])
    end
    if pat.head in (:&&, :||) && ex.head == pat.head && k == 2 && length(ex.args) > 2
        return Expr(ex.head, Expr(ex.head, ex.args[1:(end - 1)]...), ex.args[end])
    end
    return ex
end

function _literal_equal(p, e)
    p isa Number && e isa Number && return p == e && (p isa Bool) == (e isa Bool)
    p isa QuoteNode && e isa QuoteNode && return isequal(p.value, e.value)
    return isequal(p, e)
end

function _explain_failure(m::_Matcher, expr, type::Symbol)
    if isempty(m.failures)
        return "`$(_show_expr(expr))` cannot be derived from `$type`."
    end
    # The innermost (shortest) sub-expression whose top-level construct does not
    # match any production of the nonterminal it was expected to derive from.
    ex, t = argmin(f -> length(_show_expr(f[1])), m.failures)
    prods = join(unique([rule_string(m.grammar.rules[r]) for r in m.grammar.bytype[t]]), " | ")
    return "`$(_show_expr(ex))` cannot be derived from nonterminal `$t` " *
        "(its productions are: $t = $prods)."
end

_show_expr(e) = e isa Union{Expr, Symbol} ? rule_string(e) : repr(e)

"""
    text2rulenode(text, grammar, start::Symbol) -> (RuleNode, code::String)

Full pipeline from a model answer to a derivation tree. Throws a
`GrammarParseError` on failure.
"""
function text2rulenode(text::AbstractString, grammar::AbstractGrammar, start::Symbol)
    code = extract_code(text)
    isnothing(code) && throw(GrammarParseError(:no_program, "no program found in the answer"))
    expr = parse_program(code, grammar)
    return expr2rulenode_typed(expr, grammar, start), code
end
