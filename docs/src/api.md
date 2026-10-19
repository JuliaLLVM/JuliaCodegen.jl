# API reference

The API is not exported; use qualified names (`JuliaCodegen.CodegenConfig`).

```@docs
JuliaCodegen
```

## Configuration

```@docs
JuliaCodegen.CodegenConfig
```

## Facts about the running Julia

```@docs
JuliaCodegen.RuntimeFacts
JuliaCodegen.runtime_facts
JuliaCodegen.setjmp_savemask
```

## Targets

```@docs
JuliaCodegen.Target
JuliaCodegen.host_target
JuliaCodegen.c_abi_kind
JuliaCodegen.target_machine
JuliaCodegen.has_backend
JuliaCodegen.AddrSpace
```

## Drivers

```@docs
JuliaCodegen.emit_into!
JuliaCodegen.CompiledFunctions
```

## Output and pipelines

```@docs
JuliaCodegen.CodegenOutput
JuliaCodegen.codegen_output
JuliaCodegen.check_relocatable
JuliaCodegen.Pipeline
JuliaCodegen.JuliaCppPipeline
JuliaCodegen.NoPipeline
JuliaCodegen.CustomPipeline
JuliaCodegen.run_pipeline!
```

## Errors and failure policies

```@docs
JuliaCodegen.Unsupported
JuliaCodegen.unsupported
JuliaCodegen.InternalError
JuliaCodegen.FAILURE_POLICIES
JuliaCodegen.handle_failure
```
