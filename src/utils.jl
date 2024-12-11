using Herb.HerbSearch: ProgramIterator
using Herb.HerbGrammar: ContextSensitiveGrammar


function construct_iterator(::Type{T},
    grammar::ContextSensitiveGrammar,
    sym::Symbol;
    kwargs...
    ) where T<:ProgramIterator
    return T(grammar, sym; kwargs...)
end