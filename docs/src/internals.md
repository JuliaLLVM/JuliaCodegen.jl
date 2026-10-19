# Internals

The parts of the code generator, for those working on it or building on it.

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
JuliaCodegen.init_function!
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

## Calls and intrinsics

```@docs
JuliaCodegen.emit_intrinsic
JuliaCodegen.atomic_ordering
JuliaCodegen.emit_dynamic_call
JuliaCodegen.get_function!
JuliaCodegen.process_worklist!
JuliaCodegen.emit_stub!
JuliaCodegen.emit_call_info
JuliaCodegen.emit_unreachable!
JuliaCodegen.emit_guard!
JuliaCodegen.entry_alloca!
JuliaCodegen.declare_runtime
JuliaCodegen.runtime_function
```

## Builtins

```@docs
JuliaCodegen.emit_builtin
JuliaCodegen.emit_egal
JuliaCodegen.emit_f_is
JuliaCodegen.emit_isa
JuliaCodegen.emit_tag
JuliaCodegen.tag_constant
JuliaCodegen.typeof_box
JuliaCodegen.emit_if
JuliaCodegen.emit_new
JuliaCodegen.emit_store_field!
JuliaCodegen.field_address
JuliaCodegen.maybe_undef_field
JuliaCodegen.runtime_global
JuliaCodegen.memory_elements
JuliaCodegen.emit_gc_loaded
```

## Unboxed unions

```@docs
JuliaCodegen.make_union
JuliaCodegen.union_tindex_value
JuliaCodegen.union_member
JuliaCodegen.tindex_switch
JuliaCodegen.box_union
JuliaCodegen.to_union
JuliaCodegen.from_union
```

## C calls

```@docs
JuliaCodegen.c_abi_layout
JuliaCodegen.ccall_kind
JuliaCodegen.CSig
JuliaCodegen.c_function_sig
JuliaCodegen.runtime_symbol_name
JuliaCodegen.emit_symbol_address
JuliaCodegen.gc_roots
JuliaCodegen.emit_foreigncall
JuliaCodegen.emit_cglobal
```
