# Testing

`Pkg.test()` runs the package's tests, and [Aqua.jl](https://github.com/JuliaTesting/Aqua.jl)'s
checks of the package. The helpers the tests share are in `test/testhelpers.jl`.

## Differential execution

The main oracle is Julia's native code generator: `@cgtest f(args...)` runs `f(args...)`
once with native code and once with code compiled by JuliaCodegen, each on its own deep
copy of the arguments, and checks that both return `isequal` values of the same type (or
throw exceptions of the same type) and leave the arguments in the same state.
`@cgtest run=r f(args...)` uses the runner `r(f, args...)` instead of JuliaCodegen.

With `JULIACODEGEN_GC_STRESS=1`, a full garbage collection runs before every execution,
so that values the generated code does not root correctly are collected.

## IR

Tests that inspect emitted IR use [FileCheck.jl](https://github.com/JuliaLLVM/FileCheck.jl)
(`@filecheck` with `@check*` directives), and check properties of the IR rather than
whole modules.

`verify_ir(mod)` checks a module in Julia's pre-lowering IR with LLVM's verifier, with
[JuliaIR.jl](https://github.com/JuliaLLVM/JuliaIR.jl)'s GCInvariantVerifier (in its strong
mode, for the IR dialect of the running Julia), and, on Julia builds that provide it, with
the Julia dialect's verifier.
