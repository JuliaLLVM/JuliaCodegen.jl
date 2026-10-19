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

## Values

```@docs
JuliaCodegen.Repr
JuliaCodegen.repr_kind
JuliaCodegen.ghost_value
JuliaCodegen.unique_type_parameter
JuliaCodegen.FieldStorage
JuliaCodegen.field_storage
JuliaCodegen.has_references
JuliaCodegen.npointers
JuliaCodegen.union_members
JuliaCodegen.union_has_boxed
JuliaCodegen.is_unboxable_union
JuliaCodegen.is_bits_union
JuliaCodegen.union_payload_size
JuliaCodegen.union_payload_align
JuliaCodegen.union_nroots
JuliaCodegen.union_has_box
JuliaCodegen.union_tindex
JuliaCodegen.UNION_BOX_MARKER
JuliaCodegen.union_type
JuliaCodegen.Layouts
JuliaCodegen.Layout
JuliaCodegen.LayoutMode
JuliaCodegen.layout
JuliaCodegen.value_type
JuliaCodegen.primitive_nbits
JuliaCodegen.is_vector_tuple
JuliaCodegen.MAX_INLINE_BYTES
JuliaCodegen.CGVal
JuliaCodegen.ghost
JuliaCodegen.bottom
JuliaCodegen.inline
JuliaCodegen.boxed
JuliaCodegen.unboxed_union
JuliaCodegen.isconstant
JuliaCodegen.constant_value
```

## Generating functions

```@docs
JuliaCodegen.CGModule
JuliaCodegen.unique_name
JuliaCodegen.FuncInfo
JuliaCodegen.FnCtx
JuliaCodegen.AbstractFnCtx
JuliaCodegen.walk_function!
JuliaCodegen.operand
JuliaCodegen.method_instance
JuliaCodegen.get_ir
JuliaCodegen.emit_entry!
JuliaCodegen.declare_function!
JuliaCodegen.signature_argtypes
JuliaCodegen.emit_body!
JuliaCodegen.emit_jlcall_wrapper!
JuliaCodegen.literal_global
JuliaCodegen.literal_objects
JuliaCodegen.literal_pointer
JuliaCodegen.const_value
JuliaCodegen.insert_field
JuliaCodegen.extract_field
JuliaCodegen.smalltag
JuliaCodegen.type_tag
JuliaCodegen.emit_allocation
JuliaCodegen.emit_box
JuliaCodegen.emit_unbox
JuliaCodegen.convert_repr
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
