mutable struct OverheadMetrics
    analysis_ns::UInt64
    propagation_ns::UInt64
    total_ns::UInt64
    OverheadMetrics() = new(0,0,0)
end

reset!(m::OverheadMetrics) = (m.analysis_ns=0; m.propagation_ns=0; m.total_ns=0; m)

ns2s(x::Integer) = float(x) / 1e9

"""
    @measure! (metrics, field) expr

Times `expr` and adds the elapsed nanoseconds to `getfield(metrics, field)`.
"""
macro measure!(mf, ex)
    # mf is a tuple like :(metrics, :analysis_ns)
    :(begin
        local __t0__ = Base.time_ns()
        local __val__ = $(esc(ex))
        local __dt__ = Base.time_ns() - __t0__
        setfield!($(esc(mf.args[1])), $(esc(mf.args[2])), getfield($(esc(mf.args[1])), $(esc(mf.args[2]))) + __dt__)
        __val__
    end)
end