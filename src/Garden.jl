module Garden

using Herb
using Herb.HerbSearch
using Herb.HerbInterpret

include("frangel/frangel_random_iterator.jl")
include("frangel/frangel_generation.jl")
include("frangel/frangel_utils.jl")
include("frangel/frangel.jl")

export 
    FrAngelConfig,
    FrAngelConfigGeneration,

    FrAngelRandomIterator,
    FrAngelRandomIteratorState,

    modify_and_replace_program_fragments!,
    random_modify_children!,
    get_replacements,
    get_descendant_replacements!,

    random_partition,
    simplify_quick,
    _simplify_quick_once,
    symbols_minsize,
    rules_minsize,
    update_min_sizes!

    frangel

end # module Garden