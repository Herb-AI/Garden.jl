using Herb.HerbGrammar: @cfgrammar, rulenode2expr
using Herb.HerbSearch: BFSIterator
using Herb.HerbSpecification: IOExample, Problem
using Herb.HerbCore: RuleNode
using Garden: mine_fragments, select_shallowest_fragments, select_smallest_fragments, modify_grammar_frangel!, decide_frangel, NoProgramFoundError

@testset verbose=true "FrAngel" begin
    @testset "Integration tests" begin
        # Define extra grammar as FrAngel will change it.
        grammar = @cfgrammar begin
            Start = Int
            Int = Int + Int
            Int = 1 | 2
        end
        problem = Problem(
            [IOExample{Symbol, Any}(Dict(), 2)]
        )
        result = frangel(
            BFSIterator,
            grammar,
            :Start,
            problem;
            max_depth=4
        )

        @test rulenode2expr(result,grammar) == 2

        imp_problem = Problem(
            [IOExample{Symbol, Any}(Dict(), 0)]
        )
 
        # A program yielding 0 is impossible to derive from the grammar.
        @test_throws NoProgramFoundError frangel(BFSIterator, grammar, :Start, imp_problem; max_depth=4)
    end

    grammar = @cfgrammar begin
        Start = Int
        Int = Int + Int
        Int = 1 | 2
    end

    @testset "mine_fragments" begin
        rn = RuleNode(2,
            [RuleNode(2,[RuleNode(3),RuleNode(4)]),RuleNode(3)]
        ) # 2{2{3,4},3}

        fragments = collect(mine_fragments(grammar, rn))
        @test fragments[1] == rn
        @test fragments[2] == RuleNode(2,[RuleNode(3),RuleNode(4)])
    end

    @testset "select_shallowest_fragments" begin
        rn = RuleNode(2, [
            RuleNode(2, [RuleNode(2, [
                RuleNode(2, [RuleNode(3), RuleNode(4)]),
                RuleNode(3)]), 
                RuleNode(4)]),
            RuleNode(3)
        ])

        fragments = mine_fragments(grammar, rn)

        selected_fragments = select_shallowest_fragments(fragments; num_programs=3)

        @test selected_fragments[1] == RuleNode(2, [RuleNode(3), RuleNode(4)])
        @test selected_fragments[2] == RuleNode(2, [
                RuleNode(2, [RuleNode(3), RuleNode(4)]), RuleNode(3)]) 
        @test selected_fragments[3] == RuleNode(2, [RuleNode(2, [
                RuleNode(2, [RuleNode(3), RuleNode(4)]), RuleNode(3)]), 
                RuleNode(4)]
            )
        end

    @testset "modify_grammar_frangel" begin
        fragment = RuleNode(2, [RuleNode(3), RuleNode(4)])

        modify_grammar_frangel!([fragment], grammar) 
        # "Int = Fragment_Int" rule exists
        @test :Fragment_Int in grammar.rules

        # "Fragment_Int" type added to grammar
        @test haskey(grammar.bytype, :Fragment_Int)
        fragment_rule_index = first(grammar.bytype[:Fragment_Int])
        # added fragment exists in a rule
        expr = rulenode2expr(fragment, grammar)
        @test grammar.rules[fragment_rule_index] == expr
    end
end
