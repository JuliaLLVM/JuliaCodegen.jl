# JuliaCodegen.jl

A code generator for Julia written in Julia. It lowers typed, optimized Julia IR
(`IRCode`) to LLVM IR with [LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl), in the
conventions of Julia's own code generator, so that the output can be processed by
Julia's LLVM passes (or their ports in [JuliaIR.jl](https://github.com/JuliaLLVM/JuliaIR.jl))
and run by Julia's JIT, or be embedded into a module of another compiler.

Supported: Julia 1.12 and later.
