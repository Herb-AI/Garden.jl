using Garden
using Test
using Aqua
using JET

@testset "Garden.jl" begin
    # @testset "Code quality (Aqua.jl)" begin
    #     Aqua.test_all(Garden;   
    #          ambiguities=(exclude=[Garden.Herb.HerbSearch.StatsBase.:(==), Garden.Herb.HerbSearch.StatsBase.TestStat],),
    #     )
    # end
    # if VERSION >= v"1.7"
    #     @testset "Code linting (JET.jl)" begin
    #         JET.test_package(Garden; target_defined_modules = true)
    #     end
    # end
    @testset "Garden tests" begin 
        include("test_probe.jl")
        # Write your tests here.
    end
end
