# Changes of representation: boxing inline values, unboxing objects, and conversions.

"""
    JuliaCodegen.smalltag(config, T) -> Int

The small type tag of `T` (0 if it has none): objects of builtin types (`Int64`, `Bool`,
`String`, ...) carry `smalltag << 4` in their header instead of the address of their type.
"""
smalltag(config::CodegenConfig, @nospecialize T) =
    T isa DataType ? Int(T.flags) >> config.runtime.smalltag_shift : 0

"""
    JuliaCodegen.type_tag(fc, T) -> LLVM.Value

The tag that objects of type `T` carry in their header, as `julia.gc_alloc_obj` takes it:
the small tag, or the address of the type.
"""
function type_tag(fc::FnCtx, @nospecialize T)
    st = smalltag(config(fc), T)
    st == 0 && return literal_pointer(fc, T)
    iptr = LLVM.IntType(8 * config(fc).target.pointer_size)
    p = LLVM.const_inttoptr(LLVM.ConstantInt(iptr, st << 4), T_ptr())
    return LLVM.const_addrspacecast(p, T_tracked())
end

# the TBAA kind of the fields of objects of type `T`
function field_tbaa(fc::FnCtx, @nospecialize T)
    dialect(fc).minor >= v"1.14" && return :field
    return ismutabletype(T) ? :mutab : :immut
end

derived(fc::FnCtx, v::LLVM.Value) = LLVM.addrspacecast!(fc.builder, v, T_derived())

"""
    JuliaCodegen.emit_allocation(fc, T) -> LLVM.Value

Allocate an object of type `T` (`julia.gc_alloc_obj`), with uninitialized contents.
"""
emit_allocation(fc::FnCtx, @nospecialize T) =
    call_op!(fc, "julia.gc_alloc_obj", fc.current_task,
             LLVM.ConstantInt(LLVM.Int64Type(), sizeof(T)), type_tag(fc, T))

"""
    JuliaCodegen.emit_box(fc, v::CGVal) -> LLVM.Value

The value `v` as a tracked pointer to an object: its box, or the object for constants.
"""
function emit_box(fc::FnCtx, v::CGVal)
    v.kind === Boxed && return v.V
    (v.kind === Ghost || isconstant(v)) && return literal_pointer(fc, constant_value(v))
    v.kind === UnionVal && return box_union(fc, v)
    v.kind === Inline || unsupported("boxing a value represented as ", v.kind)
    b = fc.builder
    if v.vboxed !== nothing
        # the box the value came from, if it has one (native `Vboxed`)
        u = CGVal(v.typ, v.kind, v.V, v.constant, nothing)
        return emit_if(() -> v.vboxed, fc, nonnull(fc, v.vboxed), T_tracked(); name="reuse_box",
                       otherwise=() -> emit_box(fc, u))
    end
    if v.typ === Bool
        c = LLVM.trunc!(b, v.V, LLVM.Int1Type())
        return LLVM.select!(b, c, literal_pointer(fc, true), literal_pointer(fc, false))
    end
    obj = emit_allocation(fc, v.typ)
    val = v.V
    if isprimitivetype(v.typ) && LLVM.value_type(val) isa LLVM.IntegerType &&
       LLVM.width(LLVM.value_type(val)) < 8 * sizeof(v.typ)
        # a primitive type with fewer bits than its size: define the unused bits
        val = LLVM.zext!(b, val, LLVM.IntType(8 * sizeof(v.typ)))
    end
    st = LLVM.store!(b, val, derived(fc, obj); align=Base.datatype_alignment(v.typ))
    tbaa!(fc, st, field_tbaa(fc, v.typ))
    return obj
end

"""
    JuliaCodegen.emit_unbox(fc, obj, T) -> LLVM.Value

The inline value of type `T` in the object `obj`.
"""
function emit_unbox(fc::FnCtx, obj::LLVM.Value, @nospecialize T)
    ld = LLVM.load!(fc.builder, value_type(fc, T), derived(fc, obj);
                    align=Base.datatype_alignment(T))
    return tbaa!(fc, ld, field_tbaa(fc, T))
end

"""
    JuliaCodegen.convert_repr(fc, v, T) -> CGVal

The value `v` in the representation of type `T`, which must be a supertype of the type of
the value at run time.
"""
function convert_repr(fc::FnCtx, v::CGVal, @nospecialize T)
    k = repr_kind(T)
    (k === Bottom || v.kind === Bottom) && return bottom()
    k === UnionVal && return to_union(fc, v, T)
    v.kind === UnionVal && return from_union(fc, v, T)
    k === Ghost && return ghost(T, something(ghost_value(T)))
    if k === Inline
        if v.kind === Inline
            v.typ === T && return v
            # the value is known to be of type T, so representations agree
            value_type(fc, v.typ) == value_type(fc, T) &&
                return CGVal(T, Inline, v.V, v.constant, v.vboxed, v.mem)
            unsupported("converting the inline ", v.typ, " to ", T)
        elseif v.kind === Boxed
            # (an immutable object: its contents never change)
            mem = byref(fc.cgm, T) ? derived(fc, v.V) : nothing
            return inline(T, emit_unbox(fc, v.V, T); constant=v.constant, mem)
        end
        unsupported("converting the ghost ", v.typ, " to the inline ", T)
    end
    return boxed(T, emit_box(fc, v); constant=v.constant)
end
