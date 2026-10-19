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
