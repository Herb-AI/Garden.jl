include("helpers/aulile_auxiliary_functions.jl")

using Test
# using Dates
using Herb.HerbCore
using Herb.HerbSearch
using Herb.HerbGrammar
using Herb.HerbInterpret
using Herb.HerbConstraints
using Herb.HerbSpecification

using .Garden
using .Aulile

levenshtein_aux = AuxFunction(
    (expected::IOExample{<:Any,<:AbstractString}, actual::AbstractString) ->
        levenshtein!(expected.out, actual, 1, 1, 1),
    problem::Problem -> begin
        score = 0
        for example ∈ problem.spec
            score += levenshtein!(example.out, only(values(example.in)), 1, 1, 1)
        end
        return score
    end,
    0
)

simple_grammar = @csgrammar begin
    String = " "
    String = "<"
    String = ">"
    String = "-"
    String = "."
    String = x
    String = String * String
    String = replace(String, String => "")
end

@testset "Example Appending" begin
    # start_time = print_time_test_start("Running Test: Example Appending")
    problem = Problem([
        IOExample(Dict(:x => "1"), "1."),
        IOExample(Dict(:x => "2"), "2."),
        IOExample(Dict(:x => "3"), "3.")
    ])
    test_result = aulile(problem, BFSIterator, simple_grammar, :String, :String,
        levenshtein_aux, print_debug=true)
    @test !(test_result.program isa Nothing)
    @test test_result.score == levenshtein_aux.best_value
    program = rulenode2expr(test_result.program, simple_grammar)
    # println(program)
    # print_time_test_end(start_time)
end

@testset "Example Replacing" begin
    # start_time = print_time_test_start("Running Test: Example Replacing")
    problem = Problem([
        IOExample(Dict(:x => "1."), "1"),
        IOExample(Dict(:x => "2."), "2"),
        IOExample(Dict(:x => "3."), "3")
    ])
    test_result = aulile(problem, BFSIterator, simple_grammar, :String, :String,
        levenshtein_aux, print_debug=true)
    @test !(test_result.program isa Nothing)
    @test test_result.score == levenshtein_aux.best_value
    program = rulenode2expr(test_result.program, simple_grammar)
    # println(program)
    # print_time_test_end(start_time)
end

@testset "Aulile Example from Paper" begin
    # start_time = print_time_test_start("Running Test: Aulile Example from Paper")
    problem = Problem([
        IOExample(Dict(:x => "801-456-8765"), "8014568765"),
        IOExample(Dict(:x => "<978> 654-0299"), "9786540299"),
        IOExample(Dict(:x => "978.654.0299"), "9786540299")
    ])
    test_result = aulile(problem, BFSIterator, simple_grammar, :String, :String,
        levenshtein_aux, max_depth=2, print_debug=true)
    @test !(test_result.program isa Nothing)
    @test test_result.score == levenshtein_aux.best_value
    program = rulenode2expr(test_result.program, simple_grammar)
    # println(program)
    # print_time_test_end(start_time)
end

# """
#     Prints test message (name) and returns the start time
# """
# function print_time_test_start(message::AbstractString; print_separating_dashes=true)::DateTime
#     if print_separating_dashes
#         println()
#         println("--------------------------------------------------")
#     end
#     printstyled(message * "\n"; color=:blue)
#     if print_separating_dashes
#         println("--------------------------------------------------")
#     end
#     return Dates.now()
# end

# """
#     Prints and returns the duration of the test
# """
# function print_time_test_end(start_time::DateTime; end_time::DateTime=Dates.now(), test_passed=true)::DateTime
#     duration = max(end_time - start_time, Dates.Millisecond(0))
#     println()
#     if test_passed
#         printstyled("Pass. Duration: "; color=:green)
#     else
#         printstyled("Fail. Duration: "; color=:red)
#     end
#     println("$(duration)")
#     return duration
# end