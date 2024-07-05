using Herb.HerbGrammar
using Herb.HerbSearch

@testset "Running probe" begin
    examples = [
        IOExample(Dict(:arg => "a < 4 and a > 0"), "a  4 and a  0")    # <- e0 with correct space
        IOExample(Dict(:arg => "<open and <close>"), "open and close") # <- e1
    ]
    input = [example.in for example in examples]
    output = [example.out for example in examples]

    symboltable = SymbolTable(grammar)

    cost_functions = [HerbSearch.calculate_rule_cost_size, HerbSearch.calculate_rule_cost_prob]
    select_functions = [HerbSearch.selectpsol_all_cheapest, HerbSearch.selectpsol_first_cheapest, HerbSearch.selectpsol_largest_subset]
    uniform_grammar = @pcsgrammar begin
        1:S = arg
        1:S = ""
        1:S = "<"
        1:S = ">"
        1:S = my_replace(S, S, S)
        1:S = S * S
    end
    for cost_func ∈ cost_functions
        for select_func ∈ select_functions
            for grammar_to_use ∈ [uniform_grammar, grammar]
                @testset "Uniform grammar is uniform" begin
                    sum(exp.(grammar.log_probabilities)) ≈ 1
                end
                # overwrite calculate cost
                HerbSearch.calculate_rule_cost(rule_index::Int, g::ContextSensitiveGrammar) = cost_func(rule_index, g)
                # overwrite select function
                HerbSearch.select_partial_solution(partial_sols::Vector{ProgramCache}, all_selected_psols::Set{ProgramCache}) = select_func(partial_sols, all_selected_psols)

                deep_copy_grammar = deepcopy(grammar_to_use)
                iter = HerbSearch.GuidedSearchIterator(deep_copy_grammar, :S, examples, symboltable)
                max_time = 5
                runtime = @timed program = probe(examples, iter, max_time, 100)
                expression = rulenode2expr(program, grammar_to_use)
                @test runtime.time <= max_time

                received = execute_on_input(symboltable, expression, input)
                @test output == received
            end
        end
    end
end