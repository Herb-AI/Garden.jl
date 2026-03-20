using Test

using Herb.HerbCore
using Herb.HerbGrammar: @cfgrammar, rulenode2expr
using Herb.HerbSearch: BFSIterator
using Herb.HerbSpecification: IOExample, Problem
using Herb.HerbCore: RuleNode, Hole, @rulenode
using Herb.HerbInterpret: make_interpreter

using Garden: FrAngel
using .FrAngel: frangel, mine_fragments, select_shallowest_fragments,
                select_smallest_fragments, modify_grammar_frangel!,
                decide_frangel, NoProgramFoundError

using RuntimeGeneratedFunctions
RuntimeGeneratedFunctions.init(@__MODULE__)

@testset verbose = true "FrAngel" begin
    @testset "Integration tests" begin
        grammar = @cfgrammar begin
            Start = Int
            Int = Int + Int
            Int = 1 | 2
            Int = x
        end

        problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), x + 1) for x in 1:3])

        result = frangel(
            BFSIterator,
            grammar,
            :Start,
            problem;
            interpret_builder = make_interpreter,
            input_symbols = [:x],
            interpret_target_module = @__MODULE__,
            interpret_cache_module = @__MODULE__,
            max_depth = 4,
            allow_errors=false
        )

        @test !isnothing(result)
        @test all(
            make_interpreter(
                grammar;
                input_symbols = [:x],
                target_module = @__MODULE__,
                cache_module = @__MODULE__,
            )(result, ex.in) == ex.out for ex in problem.spec
        )

        imp_grammar = @cfgrammar begin
            Start = Int
            Int = Int + Int
            Int = 1 | 2
            Int = x
        end

        imp_problem = Problem([IOExample(Dict{Symbol, Any}(:x => x), 0) for x in 1:3])

        result =  frangel(
            BFSIterator,
            imp_grammar,
            :Start,
            imp_problem;
            interpret_builder = make_interpreter,
            input_symbols = [:x],
            interpret_target_module = @__MODULE__,
            interpret_cache_module = @__MODULE__,
            max_depth = 4,
            allow_errors=false
        )

        @test isnothing(result)
    end

    grammar = @cfgrammar begin
        Start = Int
        Int = Int + Int
        Int = 1 | 2
    end

    @testset "decide_frangel" begin
        interp = make_interpreter(
            grammar;
            target_module = @__MODULE__,
            cache_module = @__MODULE__,
        )

        program = @rulenode 4
        problem = Problem([IOExample(Dict{Symbol, Any}(), 2)])

        @test decide_frangel(program, problem, interp; allow_errors = false) == 1.0
    end

    @testset "mine_fragments" begin
        rn = @rulenode 2{2{3, 4}, 3}

        fragments = mine_fragments(grammar, rn)
        @test rn in fragments
        @test !((@rulenode 3) in fragments)
        @test (@rulenode 2{3, 4}) in fragments

        complete = @rulenode 2{3, 4}
        rn_hole = RuleNode(2, [
            complete, Hole([0, 0, 1, 1])
        ])
        fragments_hole = mine_fragments(grammar, rn_hole)
        @test !(rn_hole in fragments_hole)
        @test complete in fragments_hole
    end

    @testset "select_smallest_fragments" begin
        rn = @rulenode 2{2{2{3, 4}, 3}, 4}
        fragments = mine_fragments(grammar, rn)

        selected_fragments = select_smallest_fragments(fragments; num_programs = 2)

        @test length(selected_fragments) == 2
        @test selected_fragments[1] == @rulenode 2{3, 4}
        @test selected_fragments[2] == @rulenode 2{2{3, 4}, 3}
    end

    @testset "select_shallowest_fragments" begin
        rn = @rulenode 2{2{2{2{3, 4}, 3}, 4}, 3}

        fragments = mine_fragments(grammar, rn)
        selected_fragments = select_shallowest_fragments(fragments; num_programs = 3)

        @test selected_fragments[1] == @rulenode 2{3, 4}
        @test selected_fragments[2] == @rulenode 2{2{3, 4}, 3}
        @test selected_fragments[3] == @rulenode 2{2{2{3, 4}, 3}, 4}
    end

    @testset "modify_grammar_frangel!" begin
        grammar = @cfgrammar begin
            Start = Int
            Int = Int + Int
            Int = 1 | 2
        end

        fragment = @rulenode 2{3, 4}
        expr = rulenode2expr(fragment, grammar)

        modify_grammar_frangel!([fragment], grammar)

        @test haskey(grammar.bytype, :Fragment_Int)

        fragment_rule_index = first(grammar.bytype[:Fragment_Int])
        @test grammar.rules[fragment_rule_index] == expr

        @test any(rule == :Fragment_Int for rule in grammar.rules)
    end
end