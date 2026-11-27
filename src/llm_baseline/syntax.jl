#=
Expression helpers used both to show the grammar to the model (`prompts.jl`) and
to read the model's answer back (`parsing.jl`), so that the syntax the model is
shown is the syntax the parser accepts.

All direct access to the grammar's fields is in this file as well: HerbGrammar
has no public accessor for a grammar's rules or for the rules of a nonterminal.
=#

_rules(grammar::AbstractGrammar) = grammar.rules
_productions(grammar::AbstractGrammar, nonterminal::Symbol) = grammar.bytype[nonterminal]
_nonterminals_in_order(grammar::AbstractGrammar) = unique(grammar.types)

"""
    normalize_expr(e)

Canonical form used on both sides of the matching: no line numbers, no
single-statement blocks, `elseif` written as `if`, and `a; b` on one line (which
Julia parses as `:toplevel`) written as a block.
"""
function normalize_expr(e)
    e isa Expr || return e
    args = Any[normalize_expr(a) for a in e.args if !(a isa LineNumberNode)]
    head = e.head == :elseif ? :if : e.head == :toplevel ? :block : e.head
    head == :block && length(args) == 1 && return only(args)
    return Expr(head, args...)
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
            return _operand(e.args[2]) * " $f " * _operand(e.args[3])
        end
        return string(f) * "(" * join(_rs.(e.args[2:end]), ", ") * ")"
    end
    return string(e)
end

# An operand of an infix operator, bracketed if it is itself an infix call, so
# that `a + (b + c)` does not come out as `a + b + c`.
function _operand(e)
    infix = e isa Expr && e.head == :call && e.args[1] isa Symbol &&
        Base.isbinaryoperator(e.args[1]) && length(e.args) == 3
    return infix ? "(" * _rs(e) * ")" : _rs(e)
end
