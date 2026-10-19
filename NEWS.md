# JuliaCodegen.jl release notes

## Unreleased

- Initial package skeleton.
- Test helpers: differential execution against native code (`@cgtest`), IR verification
  with JuliaIR.jl's GCInvariantVerifier, FileCheck.jl.
- `CodegenConfig`: the target (`Target`, `host_target`), and the failure
  policies for unsupported code and internal errors.
- The IR dialect (`JuliaIR.Dialect`) and runtime facts (`RuntimeFacts`) of the running
  Julia, from JuliaIR.jl.
- The intrinsics of Julia's IR (`declare_op`, `call_op!`, `write_barrier!`), the
  function prologue (pgcstack, current task, thread-local state, safepoint poll) and the
  TBAA tree, as the running Julia's code generator emits them.
- The representation of values (`repr_kind`: ghost, inline, unboxed union or boxed),
  the LLVM layouts of inline types (`Layouts`), the LLVM type of unboxed unions, and
  `CGVal`.
- Functions from `IRCode`: the IR walker, function bodies with control flow and phis,
  boxing and unboxing, constants (objects through globals the linker binds), and jlcall
  entry wrappers (`emit_entry!`).
- Intrinsics (arithmetic, comparisons, conversions, shifts with Julia's semantics,
  checked arithmetic and division, pointers, atomics, fences, `llvmcall`), and calls
  through the runtime for everything else: dynamic dispatch for `:call`s, `jl_invoke`
  for `:invoke`s.
- Builtins: `===` (as native code: identity, contents, `jl_egal__unboxed`), `isa`,
  `typeassert`, `typeof`, `new` (inline values and objects), `getfield` and `setfield!`
  (with undefined-field checks and write barriers), `tuple`, `ifelse`, `isdefined`,
  `throw`, `sizeof`, constant `getglobal`, and constant folding.
- Unboxed unions: construction, narrowing, conversions between unions and to and from
  boxes (keeping the box a value came from), phis of unions, `isa`/`typeof`/`===` of
  union values, isbits-union fields, and conditions that may not be `Bool`.
- Direct calls: `:invoke`s call functions emitted into the same module from their own IR
  (recursion included); callees that always throw, varargs methods (for now), and
  callees with unsupported constructs call their native code (`cgm.fallbacks` says why),
  unless the configuration says to throw.
- The memory builtins (`memorynew`, `memoryrefnew`, `memoryrefget`, `memoryrefset!`,
  `memoryrefunset!`, `memoryrefoffset`) for elements stored inline, as references and as
  isbits unions, with bounds checks, `julia.gc_loaded`, the owner's write barrier, and the
  dialect's TBAA; array loops make no dynamic calls.
- `ccall` in the C ABI of the target (the platform ABIs of Julia's `abi_*.cpp`):
  scalars, aggregates by value (`byval`, `sret`), `Ref` and object arguments, variadic
  calls, `gc_safe` calls, runtime function pointers; relocatable symbol references (by
  name, or looked up on first use); `cglobal`; `GC.@preserve`; and the runtime functions
  native code emits inline.
