using Test
using JuliaCodegen
using FileCheck
using InteractiveUtils

include("testhelpers.jl")

@testset "JuliaCodegen" begin

include("harness.jl")
include("config.jl")

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(JuliaCodegen)
end

end
