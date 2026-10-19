# JuliaCodegen.jl

A code generator for Julia written in Julia. It lowers typed, optimized Julia IR
(`IRCode`) to LLVM IR with [LLVM.jl](https://github.com/JuliaLLVM/LLVM.jl), in the
conventions of Julia's own code generator: GC-tracked pointers in address spaces 10 to
13, the `julia.*` intrinsics, and Julia's calling conventions. The output is processed
by Julia's LLVM passes, or by their ports in
[JuliaIR.jl](https://github.com/JuliaLLVM/JuliaIR.jl).

## Status

Work in progress: the package is being built up from a prototype, one part at a time.

## Supported versions

Julia 1.12 and later.

## Testing

`Pkg.test()` runs the package's tests. On Julia 1.12 and later, `test/` and `docs/` are
workspace projects of the package: `julia --project=test test/runtests.jl` runs the
tests without `Pkg.test()`.
