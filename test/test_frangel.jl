using Herb.HerbGrammar: @cfgrammar
using Herb.HerbSearch: BFSIterator
using Herb.HerbSpecification: IOExample, Problem

@testset "FrAngel" begin
    grammar = @cfgrammar begin
        Int = Int + Int
        Int = 1 | 2
    end
    problem = Problem(
        [IOExample(Dict(), 2)]
    )
    result = frangel(
        BFSIterator,
        grammar,
        problem,
        10,
        20
    )
    @test !isnothing(result)
end