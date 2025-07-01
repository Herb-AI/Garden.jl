module Garden

using DocStringExtensions

include("utils.jl")
include("probe/method.jl")
include("frangel/method.jl")

export 
    Probe,
    NoProgramFoundError,
    SynthResult,
    FrAngel

end # module Garden
