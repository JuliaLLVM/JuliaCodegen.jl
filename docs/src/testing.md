# Testing

`Pkg.test()` runs the package's tests, and [Aqua.jl](https://github.com/JuliaTesting/Aqua.jl)'s
checks of the package. The helpers the tests share are in `test/testhelpers.jl`.

CI runs them on Julia 1.12, 1.13, the latest prerelease and nightly. Locally, give each
Julia version its own manifest, since `test/` and `docs/` share the package's manifest as
workspace projects: create an empty `Manifest-v1.<minor>.toml` (e.g. with
`touch Manifest-v1.14.toml`), then `julia +1.14-nightly --project -e 'using Pkg;
Pkg.resolve(); Pkg.test()'`. A manifest resolved by one version can make another fail to
precompile its standard libraries.

## Differential execution

The main oracle is Julia's native code generator: `@cgtest f(args...)` runs `f(args...)`
once with native code and once with code compiled by JuliaCodegen, each on its own deep
copy of the arguments, and checks that both return `isequal` values of the same type (or
throw exceptions of the same type) and leave the arguments in the same state.
`@cgtest run=r f(args...)` uses the runner `r(f, args...)` instead of JuliaCodegen.
Mutable results whose `==` is identity (the arguments are copies) are compared field by
field.

`test/jit.jl` runs the code: it compiles the call with `JuliaCodegen.emit_entry!`, gives
the globals of the objects the code refers to their addresses, checks the module with
`verify_ir`, runs Julia's own LLVM pipeline and adds the module to Julia's JIT through
LLVM.jl (`cgrun(f, args...)`; `test_ir(f, types)` is the IR before linking).

With `JULIACODEGEN_GC_STRESS=1`, a full garbage collection runs before every execution,
so that values the generated code does not root correctly are collected.

## IR

Tests that inspect emitted IR use [FileCheck.jl](https://github.com/JuliaLLVM/FileCheck.jl)
(`@filecheck` with `@check*` directives), and check properties of the IR rather than
whole modules.

`verify_ir(mod)` checks a module in Julia's pre-lowering IR with LLVM's verifier, with
[JuliaIR.jl](https://github.com/JuliaLLVM/JuliaIR.jl)'s GCInvariantVerifier (in its strong
mode), and, on Julia builds that provide it, with
the Julia dialect's verifier.

## Facts

The facts about the running Julia that JuliaCodegen takes from JuliaIR.jl (its IR dialect
and runtime facts) are compared with the IR of Julia's own code generator:
`test/factprobe.jl` recovers them from native IR and from object headers, independently
of JuliaIR.jl. `julia test/factprobe.jl` prints them.

## Native code

`test/nativeprobe.jl` has functions whose native code uses every intrinsic of Julia's IR
that JuliaCodegen emits. The tests compare JuliaCodegen's declarations of the intrinsics
(types and attributes), the function prologue and the TBAA tree with those of the
running Julia's code generator.

## The C ABI

`test/cabi_targets.jl` emits the C signatures of 121 `ccall`s (scalars of every width,
structs of 1 to 72 bytes, homogeneous aggregates, vectors, register exhaustion, variadic
calls) for ten targets, with `test_module_ir(f, types; triple)`, and compares them with
`test/cabi_targets.txt` and, when clang is installed, with clang's declarations of the
same C functions (up to the known differences listed there, where native Julia's ABI
differs from clang's). Set `JULIACODEGEN_CABI_REGEN=1` to rewrite the table.

## Unreleased dependencies

JuliaIR.jl and the LLVM.jl changes it needs are not released yet: `Project.toml` and
`test/Project.toml` take them from their repositories (`[sources]`), and the LLVM.jl
branch needs an LLVMExtra library built from source. CI builds it with
`.github/actions/llvm-dev`. Locally, run LLVM.jl's `deps/build_local.jl` from a checkout of
that branch under each Julia version, and copy the `LocalPreferences.toml` it writes into
the package's root and `test/`.
