using Herb.HerbGrammar: @cfgrammar
using Herb.HerbSearch: BFSIterator
using Herb.HerbSpecification: IOExample, Problem
using .Probe: probe, min_rulenode_log_probability, derivation_heuristic, 
            modify_grammar_probe, get_promising_programs_with_fitness
using Garden: NoProgramFoundError

@testset "Probe" begin
    @testset verbose=true "Integration tests" begin
        # Define extra grammar as FrAngel will change it.
        grammar = @cfgrammar begin
            Start = Int
            Int = Int + Int
            Int = |(1:5)
            Int = x
        end

        problem = Problem(
            [IOExample{Symbol, Any}(Dict(), 2)]
        )
        result = probe(
            BFSIterator,
            grammar,
            :Start,
            problem;
            max_depth = 4
        )

        @test rulenode2expr(result, grammar) == 2

        imp_problem = Problem(
            [IOExample{Symbol, Any}(Dict(), 0)]
        )

        # A program yielding 0 is impossible to derive from the grammar.
        @test_throws NoProgramFoundError probe(
            grammar, :Start, imp_problem; max_depth = 4)
    end

    grammar = @cfgrammar begin
        Start = Int
        Int = Int + Int
        Int = |(1:5)
        Int = x
    end

    @testset "modify_grammar_probe!" begin
        program = @rulenode 2{3, 4}
        fitness = 1

        orig_probs = grammar.log_probabilities

        modify_grammar_probe(Set((program, fitness)), grammar)

        new_probs = grammar.log_probabilities
        # Probabilities change
        @test orig_probs != grammar.log_probabilities
        # Test increase
        @test maximum(new_probs[[2,3,4]]) < minimum(orig_probs)
        @test minimum(new_probs[[1,5,6,7,8]]) > maximum(orig_probs)
    end

    @testset verbose=true "min_rulenode_log_probability" begin
         
    end
end