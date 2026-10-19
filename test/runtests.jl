using Test
using JuliaCodegen
using FileCheck
using InteractiveUtils

include("testhelpers.jl")
include("factprobe.jl")

@testset "JuliaCodegen" begin

include("harness.jl")
include("config.jl")
include("facts.jl")

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(JuliaCodegen)
end

end
