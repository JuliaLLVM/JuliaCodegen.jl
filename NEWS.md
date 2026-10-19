# JuliaCodegen.jl release notes

## Unreleased

- Initial package skeleton.
- Test helpers: differential execution against native code (`@cgtest`), IR verification
  with JuliaIR.jl's GCInvariantVerifier, FileCheck.jl.
- `CodegenConfig`: the target (`Target`, `host_target`), and the failure
  policies for unsupported code and internal errors.
