"""
    JuliaCodegen

A code generator for Julia written in Julia: it lowers typed, optimized Julia IR
(`IRCode`) to LLVM IR with LLVM.jl, in the conventions of Julia's own code generator
(the IR that Julia's LLVM passes consume).
"""
module JuliaCodegen

using LLVM
import Libdl

include("errors.jl")
include("target.jl")
include("config.jl")

end
