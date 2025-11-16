using Garden
using Herb


grammar = @cfgrammar begin
    Start = Int
    Int = Int + Int
    Int = |(1:5)
    Int = x
end
# problem = Problem( [IOExample{Symbol, Any}(Dict(), 2)])
problem = Problem([[IOExample(Dict(:x => x), 2x+1) for x ∈ 1:5];
                   [IOExample(Dict(:x => 2), 0)]])

result = probe(
    grammar,
    :Start,
    problem;
    max_depth = 4
)

println(result)

