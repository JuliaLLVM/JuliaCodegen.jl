using Test
using JuliaCodegen
using FileCheck
using InteractiveUtils
import Libdl

include("testhelpers.jl")
include("factprobe.jl")
include("nativeprobe.jl")
include("jit.jl")

@testset "JuliaCodegen" begin

include("harness.jl")
include("config.jl")
include("facts.jl")
include("ops.jl")
include("repr.jl")
include("walker.jl")
include("intrinsics.jl")
include("builtins.jl")
include("unions.jl")
include("calls.jl")
include("memory.jl")
include("ccall.jl")
include("exceptions.jl")
include("specsig.jl")
include("cabi_targets.jl")

@testset "Aqua" begin
    using Aqua
    Aqua.test_all(JuliaCodegen)
end

end
