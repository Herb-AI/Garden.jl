# FrAngel

[Publication (Open Access)](https://doi.org/10.1145/3290386)

```
@article{DBLP:journals/pacmpl/ShiSL19,
  author       = {Kensen Shi and
                  Jacob Steinhardt and
                  Percy Liang},
  title        = {FrAngel: component-based synthesis with control structures},
  journal      = {Proc. {ACM} Program. Lang.},
  volume       = {3},
  number       = {{POPL}},
  pages        = {73:1--73:29},
  year         = {2019}
}
```

FrAngel is a synthesis strategy that alternates between enumerating candidate programs, keeping promising partial solutions, mining fragments from them, and extending the grammar with those fragments.

This implementation only supports the fragment-mining part of FrAngel.  It does not implement angelic conditions.

## How to run
```julia
using Garden.FrAngel: frangel
using Herb
using Herb.HerbSearch: BFSIterator

using RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

# Define the grammar
grammar = @cfgrammar begin
    Start = Int
    Int = Int + Int
    Int = |(1:3)
    Int = x
end

# Define a toy problem
problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), x + 1) for x in 1:5])

# Run FrAngel
program = frangel(
    BFSIterator,
    grammar,
    :Start,
    problem;
    interpret_builder = HerbInterpret.make_interpreter,
    input_symbols = [:x],
    interpret_target_module = @__MODULE__,
    interpret_cache_module = @__MODULE__,
    max_depth = 4,
    frangel_iterations = 3,
    allow_errors=false
)

# Print result, if found
if isnothing(program)
    println("No solution found.")
else
    println("Found:")
    println(rulenode2expr(program, grammar))
end
```
