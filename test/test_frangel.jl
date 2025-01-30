using Herb.HerbGrammar: @cfgrammar
using Herb.HerbSearch: BFSIterator
using Herb.HerbSpecification: IOExample, Problem
using Garden: mine_fragments, select_shallowest_fragments, select_smallest_fragments, modify_grammar_frangel, decide_frangel

@testset "FrAngel" begin
    grammar = @cfgrammar begin
        Start = Int
        Int = Int + Int
        Int = 1 | 2
    end

    @testset "Integration tests" begin
        problem = Problem(
            [IOExample(Dict(), 2)]
        )
        result = frangel(
            BFSIterator,
            grammar,
            :Int,
            problem;
            max_depth=4
        )

        @test rulenode2expr(result) == 2
    end

    @testset "mine_fragments" begin
        rn = RuleNode(2,
            [RuleNode(2,[RuleNode(3),RuleNode(4)]),RuleNode(3)]
        ) # 2{2{3,4},3}


    end
end
