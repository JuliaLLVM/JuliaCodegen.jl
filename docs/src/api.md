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

## Julia's IR

```@docs
JuliaCodegen.declare_op
JuliaCodegen.call_op!
JuliaCodegen.write_barrier!
JuliaCodegen.OpSpec
JuliaCodegen.get_pgcstack!
JuliaCodegen.current_task!
JuliaCodegen.current_ptls!
JuliaCodegen.safepoint_poll!
JuliaCodegen.TBAA
JuliaCodegen.tbaa_tree
JuliaCodegen.tbaa_tag
JuliaCodegen.tbaa!
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

## Errors and failure policies

```@docs
JuliaCodegen.Unsupported
JuliaCodegen.unsupported
JuliaCodegen.InternalError
JuliaCodegen.FAILURE_POLICIES
JuliaCodegen.handle_failure
```
