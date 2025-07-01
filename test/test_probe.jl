using Herb.HerbCore: @rulenode, RuleNode
using Herb.HerbGrammar: @cfgrammar
using Herb.HerbSpecification: IOExample, Problem
using Garden: Probe, NoProgramFoundError, SynthResult
using .Probe: probe, get_promising_programs_with_fitness, modify_grammar_probe!

@testset "Probe" begin
    @testset verbose=true "Integration tests" begin
        # Define extra grammar as FrAngel will change it.
        grammar = @cfgrammar begin
            Start = Int
            Int = Int + Int
            Int = |(1:5)
        end

        problem = Problem([IOExample(Dict(:x => x), 2x+1) for x ∈ 1:5])
        result = probe(
            grammar,
            :Start,
            problem;
            max_depth = 4
        )

        @test rulenode2expr(result, grammar) == 2

        imp_problem = Problem([[IOExample(Dict(:x => x), 2x+1) for x ∈ 1:5];
                   [IOExample(Dict(:x => 2), 0)]])

        # A program yielding 0 is impossible to derive from the grammar.
        @test_throws NoProgramFoundError probe(
            grammar, :Start, imp_problem; max_depth = 3)
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

        modify_grammar_probe!(Set{Tuple{RuleNode, Real}}((program, fitness)), grammar)

        new_probs = grammar.log_probabilities
        # Probabilities change
        @test orig_probs != grammar.log_probabilities
        # Test increase
        @test maximum(new_probs[[2,3,4]]) < minimum(orig_probs)
        @test minimum(new_probs[[1,5,6,7,8]]) > maximum(orig_probs)
    end
end