using Garden.FrAngel: frangel
using Herb
using Herb.HerbSearch: CostBasedBottomUpIterator

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