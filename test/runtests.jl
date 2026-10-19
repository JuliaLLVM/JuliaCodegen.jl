using Test
using JuliaCodegen
using FileCheck

include("testhelpers.jl")

@testset "JuliaCodegen" begin

include("harness.jl")

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(JuliaCodegen)
end

end
