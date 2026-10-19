# API reference

The API is not exported; use qualified names (`JuliaCodegen.CodegenConfig`).

```@docs
JuliaCodegen
```

## Configuration

```@docs
JuliaCodegen.CodegenConfig
JuliaCodegen.OLDEST_JULIA
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

## Runtime capabilities

```@docs
JuliaCodegen.Capabilities
JuliaCodegen.capabilities
JuliaCodegen.require
```

## Errors and failure policies

```@docs
JuliaCodegen.Unsupported
JuliaCodegen.unsupported
JuliaCodegen.InternalError
JuliaCodegen.MissingCapability
JuliaCodegen.FAILURE_POLICIES
JuliaCodegen.handle_failure
```
