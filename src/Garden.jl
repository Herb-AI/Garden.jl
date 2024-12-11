module Garden

using DocStringExtensions
using Herb

include("utils.jl")
include("frangel/method.jl")
export 
    frangel, 
    decide_frangel, 
    modify_grammar_frangel,
    get_promising_programs

end # module Garden
