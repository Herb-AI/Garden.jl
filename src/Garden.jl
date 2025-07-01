module Garden

using DocStringExtensions

include("utils.jl")
include("probe/method.jl")

export 
    Probe,
    NoProgramFoundError,
    SynthResult

end # module Garden
