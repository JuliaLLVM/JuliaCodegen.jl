"""
    JuliaCodegen

A code generator for Julia written in Julia: it lowers typed, optimized Julia IR
(`IRCode`) to LLVM IR with LLVM.jl, in the conventions of Julia's own code generator
(the IR that Julia's LLVM passes consume).
"""
module JuliaCodegen

using LLVM
import JuliaIR
import Libdl

const CC = Base.Compiler

include("errors.jl")
include("target.jl")
include("facts.jl")
include("config.jl")
include("tbaa.jl")
include("ops.jl")
include("prologue.jl")
include("repr.jl")
include("layout.jl")
include("values.jl")
include("walk.jl")
include("context.jl")
include("constants.jl")
include("boxing.jl")
include("function.jl")
include("debuginfo.jl")
include("runtime.jl")
include("calls.jl")
include("intrinsics.jl")
include("egal.jl")
include("builtins.jl")
include("unions.jl")
include("memory.jl")
include("cabi.jl")
include("ccall.jl")
include("exceptions.jl")
include("specsig.jl")
include("cfunction.jl")
include("ir.jl")
include("output.jl")
include("emit_into.jl")
include("jit.jl")

end
