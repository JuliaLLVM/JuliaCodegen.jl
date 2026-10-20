# Lowering of builtin functions (`Core.Builtin`). An emitter returns `nothing` for what
# it doesn't handle, and the call then goes to the runtime.

## type tags

"""
    JuliaCodegen.emit_tag(fc, obj) -> LLVM.Value

The tag of the object `obj` (the masked header: a small tag, or the address of its type)
as an integer, read through `julia.typeof` as native code does (AllocOpt rewrites it for
allocations it moves to the stack, which have no header).
"""
function emit_tag(fc::FnCtx, obj::LLVM.Value)
    typ = call_op!(fc, "julia.typeof", obj)
    p = call_op!(fc, "julia.pointer_from_objref", derived(fc, typ))
    return LLVM.ptrtoint!(fc.builder, p, iptr_type(fc))
end

"""
    JuliaCodegen.tag_constant(fc, T) -> LLVM.Value

The tag of objects of type `T`, as an integer to compare with `emit_tag`'s.
"""
function tag_constant(fc::FnCtx, @nospecialize T)
    st = smalltag(config(fc), T)
    st == 0 || return iptr(fc, st << 4)
    # the untracked pointer loaded from the type's global (a tracked pointer may not be
    # cast to an integer)
    raw = LLVM.operands(literal_pointer(fc, T))[1]
    return LLVM.position!(fc.builder, LLVM.after(raw)) do
        LLVM.ptrtoint!(fc.builder, raw, iptr_type(fc))
    end
end

"""
    JuliaCodegen.typeof_box(fc, obj) -> LLVM.Value

The type of the object `obj`: its tag, or for builtin types the entry of the small tag in
`jl_small_typeof`.
"""
function typeof_box(fc::FnCtx, obj::LLVM.Value)
    b = fc.builder
    typ = call_op!(fc, "julia.typeof", obj)
    tag = LLVM.ptrtoint!(b, call_op!(fc, "julia.pointer_from_objref", derived(fc, typ)), iptr_type(fc))
    small = LLVM.icmp!(b, LLVM.API.LLVMIntULT, tag, iptr(fc, config(fc).runtime.max_small_tag << 4))
    return emit_if(fc, small, T_tracked(); name="typeof", otherwise=typ) do
        table = runtime_global(fc.cgm.mod, :jl_small_typeof, LLVM.Int8Type())
        p = LLVM.load!(b, T_ptr(), LLVM.inbounds_gep!(b, LLVM.Int8Type(), table, [tag]);
                       align=config(fc).target.pointer_size)
        tbaa!(fc, p, :const)
        p.metadata[LLVM.MD_nonnull] = LLVM.MDNode(LLVM.Metadata[])
        LLVM.addrspacecast!(b, p, T_tracked())
    end
end

"""
    JuliaCodegen.emit_if(then, fc, cond, ty; name, otherwise) -> LLVM.Value

`then()` if the `i1` `cond`, else `otherwise` (a value, or a function returning one), of
LLVM type `ty`.
"""
function emit_if(then, fc::FnCtx, cond::LLVM.Value, ty::LLVM.LLVMType; name::String="if",
                 otherwise)
    b = fc.builder
    f = current_function(fc)
    tbb, ebb, done = LLVM.BasicBlock(f, name * "_then"), LLVM.BasicBlock(f, name * "_else"),
                     LLVM.BasicBlock(f, name * "_done")
    LLVM.br!(b, cond, tbb, ebb)
    LLVM.position!(b, LLVM.at_end(tbb))
    tv = then()
    tend = current_block(b)
    LLVM.br!(b, done)
    LLVM.position!(b, LLVM.at_end(ebb))
    ev = otherwise isa Function ? otherwise() : otherwise
    eend = current_block(b)
    LLVM.br!(b, done)
    LLVM.position!(b, LLVM.at_end(done))
    phi = LLVM.phi!(b, ty)
    append!(LLVM.incoming(phi), [(tv, tend), (ev, eend)])
    return phi
end

## isa

"""
    JuliaCodegen.emit_isa(fc, x, T) -> Union{LLVM.Value,Nothing}

The `i1` of `isa(x, T)` for a type `T` known at compile time: decided at compile time, a
comparison of the tag for concrete types (and unions of them), `jl_subtype` of the
value's type otherwise.
"""
function emit_isa(fc::FnCtx, x::CGVal, @nospecialize(T))
    b = fc.builder
    x.typ <: T && return i1(true)
    typeintersect(x.typ, T) === Union{} && return i1(false)
    x.kind === UnionVal && return union_isa(fc, x, T)
    x.kind === Boxed || return nothing
    if T isa DataType && isconcretetype(T)
        return LLVM.icmp!(b, LLVM.API.LLVMIntEQ, emit_tag(fc, x.V), tag_constant(fc, T))
    end
    if T isa Union && all(M -> M isa DataType && isconcretetype(M), Base.uniontypes(T))
        tag = emit_tag(fc, x.V)
        r = i1(false)
        for M in Base.uniontypes(T)
            r = LLVM.or!(b, r, LLVM.icmp!(b, LLVM.API.LLVMIntEQ, tag, tag_constant(fc, M)))
        end
        return r
    end
    (T isa Type && !Base.has_free_typevars(T)) || return nothing
    f = runtime_function(fc, :jl_subtype)
    r = LLVM.call!(b, LLVM.function_type(f), f, LLVM.Value[typeof_box(fc, x.V), literal_pointer(fc, T)])
    return LLVM.icmp!(b, LLVM.API.LLVMIntNE, r, LLVM.ConstantInt(LLVM.Int32Type(), 0))
end

## fields

"Whether field `i` of `T` may be left undefined by a constructor (`new` with fewer values)."
maybe_undef_field(@nospecialize(T), i::Int) = i > fieldcount(T) - T.name.n_uninitialized

# the selector byte of an isbits-union field follows its payload
union_selector_address(fc::FnCtx, addr::LLVM.Value, @nospecialize(FT)) =
    LLVM.inbounds_gep!(fc.builder, LLVM.Int8Type(), addr, [iptr(fc, union_payload_size(FT))])

# the value of the isbits-union field at `addr`
function load_union_field(fc::FnCtx, addr::LLVM.Value, @nospecialize(T), @nospecialize(FT))
    b = fc.builder
    tb = field_tbaa(fc, T)
    payload = tbaa!(fc, LLVM.load!(b, LLVM.ArrayType(LLVM.Int8Type(), union_payload_size(FT)), addr; align=1), tb)
    sel = tbaa!(fc, LLVM.load!(b, LLVM.Int8Type(), union_selector_address(fc, addr, FT)), tb)
    return make_union(fc, FT, payload, LLVM.add!(b, sel, i8(1)))
end

"The address of field `i` of the object `obj` of type `T` (a derived pointer)."
field_address(fc::FnCtx, obj::LLVM.Value, @nospecialize(T), i::Int) =
    LLVM.inbounds_gep!(fc.builder, LLVM.Int8Type(), derived(fc, obj), [iptr(fc, fieldoffset(T, i))])

# the references in the inline value `agg` of type `T`, and their byte offsets in it, in
# the order of the offsets
function reference_values(fc::FnCtx, agg::LLVM.Value, @nospecialize T)
    out = LLVM.Value[]
    lay = layout(fc, T)
    for i in 1:fieldcount(T)
        idx = lay.fieldidx[i]
        idx < 0 && continue
        if lay.storage[i] === FieldPointer
            push!(out, extract_field(fc, lay, agg, idx))
        elseif has_references(fieldtype(T, i))
            append!(out, reference_values(fc, extract_field(fc, lay, agg, idx), fieldtype(T, i)))
        end
    end
    return out
end

function reference_offsets(@nospecialize(T), base::Int=0, out=Int[])
    for i in 1:fieldcount(T)
        s = field_storage(T, i)
        off = base + Int(fieldoffset(T, i))
        if s === FieldPointer
            push!(out, off)
        elseif s === FieldInline && has_references(fieldtype(T, i))
            reference_offsets(fieldtype(T, i), off, out)
        end
    end
    return out
end

function store_field!(fc::FnCtx, addr::LLVM.Value, v::LLVM.Value, @nospecialize(T), @nospecialize(FT))
    st = LLVM.store!(fc.builder, v, addr; align=field_alignment(fc, T, FT))
    return tbaa!(fc, st, field_tbaa(fc, T))
end

field_alignment(fc::FnCtx, @nospecialize(T), @nospecialize(FT)) =
    field_storage(FT) === FieldPointer ? config(fc).target.pointer_size :
    min(Base.datatype_alignment(FT), 16)

"""
    JuliaCodegen.emit_store_field!(fc, obj, T, i, v; barrier) -> Bool

Store `v` into field `i` of the object `obj` of type `T`, with the write barrier if
`barrier`; `false` if the field is stored in a way this doesn't handle yet.
"""
function emit_store_field!(fc::FnCtx, obj::LLVM.Value, @nospecialize(T), i::Int, v::CGVal;
                           barrier::Bool)
    FT = fieldtype(T, i)
    s = field_storage(T, i)
    s === FieldGhost && return true
    s === FieldBlob && return false
    addr = field_address(fc, obj, T, i)
    b = fc.builder
    if s === FieldUnion
        # the payload, then the selector byte after it (the type index - 1); isbits
        # unions have no references
        val = convert_repr(fc, v, FT)
        tbaa!(fc, LLVM.store!(b, union_payload_value(fc, val), addr; align=1), field_tbaa(fc, T))
        sel = LLVM.sub!(b, union_tindex_value(fc, val), i8(1))
        tbaa!(fc, LLVM.store!(b, sel, union_selector_address(fc, addr, FT)), field_tbaa(fc, T))
    elseif s === FieldInline
        val = convert_repr(fc, v, FT)
        store_field!(fc, addr, val.V, T, FT)
        if barrier && has_references(FT)
            fields = LLVM.Value[LLVM.inbounds_gep!(b, LLVM.Int8Type(), addr, [iptr(fc, o)])
                                for o in reference_offsets(FT)]
            write_barrier!(b, fc.cgm.mod, dialect(fc), obj, fields, reference_values(fc, val.V, FT))
        end
    else
        p = emit_box(fc, v)
        store_field!(fc, addr, p, T, FT)
        barrier && write_barrier!(b, fc.cgm.mod, dialect(fc), obj, addr, p)
    end
    return true
end

# an inline value of type `T` from its field values
function emit_new_inline(fc::FnCtx, @nospecialize(T), args::Vector{CGVal})
    length(args) == fieldcount(T) || return nothing
    lay = layout(fc, T)
    agg = LLVM.UndefValue(lay.llvm)
    for i in 1:fieldcount(T)
        idx = lay.fieldidx[i]
        idx < 0 && continue
        FT = fieldtype(T, i)
        v = lay.storage[i] === FieldInline ? convert_repr(fc, args[i], FT).V : emit_box(fc, args[i])
        agg = insert_field(fc, lay, agg, v, idx)
    end
    return inline(T, agg)
end

"""
    JuliaCodegen.emit_new(fc, T, args) -> Union{CGVal,Nothing}

A value of the concrete type `T` with the field values `args`: an inline value, or an
object.
"""
function emit_new(fc::FnCtx, @nospecialize(T), args::Vector{CGVal})
    (T isa DataType && isconcretetype(T)) || return nothing
    k = repr_kind(T)
    k === Ghost && return ghost(T, something(ghost_value(T)))
    k === Inline && return emit_new_inline(fc, T, args)
    (isprimitivetype(T) || T <: GenericMemory || T === String) && return nothing
    n = fieldcount(T)
    length(args) <= n || return nothing
    any(i -> field_storage(T, i) === FieldBlob, 1:n) && return nothing
    n > 0 && fieldoffset(T, 1) > 0 && return nothing    # the lock of large atomic fields
    # box the field values first: an allocation between the object's and its stores
    # would let the GC scan its uninitialized reference fields
    args = CGVal[field_storage(T, i) === FieldPointer && !(a.kind in (Boxed, Ghost)) ?
                 boxed(a.typ, emit_box(fc, a); constant=a.constant) : a
                 for (i, a) in enumerate(args)]
    obj = emit_allocation(fc, T)
    for i in 1:n
        s = field_storage(T, i)
        s === FieldGhost && continue
        if i <= length(args)
            emit_store_field!(fc, obj, T, i, args[i]; barrier=false) || return nothing
        elseif s === FieldPointer
            store_field!(fc, field_address(fc, obj, T, i), LLVM.null(T_tracked()), T, fieldtype(T, i))
        elseif s === FieldUnion
            # an undefined isbits-union field has selector 0
            FT = fieldtype(T, i)
            tbaa!(fc, LLVM.store!(fc.builder, i8(0), union_selector_address(fc, field_address(fc, obj, T, i), FT)),
                  field_tbaa(fc, T))
        elseif has_references(fieldtype(T, i))
            # the references of an undefined inline field are null
            FT = fieldtype(T, i)
            store_field!(fc, field_address(fc, obj, T, i), LLVM.null(value_type(fc, FT)), T, FT)
        end
    end
    return boxed(T, obj)
end

function emit_new!(fc::FnCtx, @nospecialize(T), args, @nospecialize(typ))
    args = CGVal[args...]
    # a value of a field's type that is not the field's: `new` throws (a TypeError)
    for i in 1:min(length(args), T isa DataType ? fieldcount(T) : 0)
        FT = fieldtype(T, i)
        typeintersect(args[i].typ, FT) === Union{} && return emit_new_runtime(fc, T, args, typ)
        args[i].typ <: FT || return emit_new_runtime(fc, T, args, typ)
    end
    r = emit_new(fc, T, args)
    r === nothing || return r
    return emit_new_runtime(fc, T, args, typ)
end

# `new` by the runtime (`jl_new_structv`, which has the signature of a jlcall with the type
# as its function), which also throws the errors of invalid field values
function emit_new_runtime(fc::FnCtx, T, args, @nospecialize(typ))
    Tv = T isa CGVal ? T : const_value(fc, T)
    r = call_op!(fc, "julia.call", runtime_function(fc, :jl_new_structv), emit_box(fc, Tv),
                 LLVM.Value[emit_box(fc, a) for a in args]...)
    typ === Union{} && return emit_unreachable!(fc)
    return convert_repr(fc, boxed(Any, r), typ)
end

emit_new_dynamic!(fc::FnCtx, T::CGVal, args, @nospecialize(typ)) =
    emit_new_runtime(fc, T, CGVal[args...], typ)

# a read of a global that is not constant, by the runtime
# A global (not a constant) is read and written through its binding's `value`, as native
# code does (`emit_globalop`): with an unordered load, or a release store and the binding's
# write barrier. Bindings of other kinds (imported, not yet resolved) go through the
# runtime, as do assignments of globals with a declared type, which convert the value.
const BINDING_VALUE_OFFSET = fieldoffset(Core.Binding, Base.fieldindex(Core.Binding, :value))

# the binding of the global `ref` in the world of the code and its declared type, if it is
# a global
function direct_binding(fc::FnCtx, ref::GlobalRef)
    p = Base.lookup_binding_partition(codegen_world(fc), ref)
    Base.binding_kind(p) == Base.PARTITION_KIND_GLOBAL || return nothing
    return convert(Core.Binding, ref), p.restriction
end

# the address of the value of the binding `bnd`: an untracked pointer into it, as native
# code addresses it (through the global that holds the binding's address)
function binding_value_address(fc::FnCtx, bnd::Core.Binding)
    t = literal_pointer(fc, bnd)
    raw = t isa LLVM.AddrSpaceCastInst ? LLVM.operands(t)[1] : LLVM.addrspacecast!(fc.builder, t, T_ptr())
    return LLVM.inbounds_gep!(fc.builder, LLVM.Int8Type(), raw, [iptr(fc, BINDING_VALUE_OFFSET)])
end

function nonconst_global(fc::FnCtx, ref::GlobalRef)
    d = direct_binding(fc, ref)
    b = fc.builder
    if d === nothing
        # another binding (imported, not yet resolved, undefined): its value from the
        # runtime (`jl_get_binding_value_seqcst`), as native code reads it
        bnd = convert(Core.Binding, ref)
        t = literal_pointer(fc, bnd)
        raw = t isa LLVM.AddrSpaceCastInst ? LLVM.operands(t)[1] : LLVM.addrspacecast!(b, t, T_ptr())
        gb = declare_runtime(fc.cgm.mod, dialect(fc), :jl_get_binding_value_seqcst)
        v = LLVM.call!(b, LLVM.function_type(gb), gb, LLVM.Value[raw])
        T = Any
    else
        bnd, T = d
        v = LLVM.load!(b, T_tracked(), binding_value_address(fc, bnd))
        LLVM.ordering!(v, LLVM.API.LLVMAtomicOrderingUnordered)
        LLVM.alignment!(v, config(fc).target.pointer_size)
        tbaa!(fc, v, :binding)
    end
    # undefined: an UndefVarError, from the runtime as native code's
    f = current_function(fc)
    err = LLVM.BasicBlock(f, "err")
    ok = LLVM.BasicBlock(f, "ok")
    LLVM.br!(b, nonnull(fc, v), ok, err)
    LLVM.position!(b, LLVM.at_end(err))
    rooted(x) = LLVM.addrspacecast!(b, literal_pointer(fc, x), LLVM.PointerType(AddrSpace.CalleeRooted))
    uve = declare_runtime(fc.cgm.mod, dialect(fc), :jl_undefined_var_error)
    LLVM.call!(b, LLVM.function_type(uve), uve, LLVM.Value[rooted(ref.name), rooted(ref.mod)])
    LLVM.unreachable!(b)
    LLVM.position!(b, LLVM.at_end(ok))
    return boxed(T isa Type ? T : Any, v)
end

# `global ref = v` of a global through its binding, as native code does, when `v` is of the
# global's type (no conversion); `false` for other bindings
function emit_binding_assignment!(fc::FnCtx, ref::GlobalRef, v::CGVal)
    d = direct_binding(fc, ref)
    (d === nothing || !(d[2] isa Type && v.typ <: d[2])) && return false
    bnd, _ = d
    b = fc.builder
    p = emit_box(fc, v)
    addr = binding_value_address(fc, bnd)
    st = LLVM.store!(b, p, addr)
    LLVM.ordering!(st, LLVM.API.LLVMAtomicOrderingRelease)
    LLVM.alignment!(st, config(fc).target.pointer_size)
    tbaa!(fc, st, :binding)
    write_barrier!(b, fc.cgm.mod, dialect(fc), literal_pointer(fc, bnd),
                   LLVM.addrspacecast!(b, addr, T_derived()), p)
    return true
end

# the field index of the constant field `f` of `T`
function field_index(@nospecialize(T), f::CGVal)
    isconstant(f) || return nothing
    fv = constant_value(f)
    if fv isa Symbol
        i = Base.fieldindex(T, fv, false)
        return i == 0 ? nothing : i
    elseif fv isa Int
        return 1 <= fv <= fieldcount(T) ? fv : nothing
    end
    return nothing
end

# a null check of a reference that is undefined when null: the runtime's UndefRefError
undef_check!(fc::FnCtx, p::LLVM.Value) = emit_raise_unless!(fc, nonnull(fc, p), UndefRefError())

# `getfield(x, f, [order], [boundscheck])`
function emit_getfield(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    2 <= length(args) <= 4 || return nothing
    x = args[1]
    T = x.typ
    (T isa DataType && isconcretetype(T)) || return nothing
    i = field_index(T, args[2])
    if i === nothing
        (args[2].typ === Int && args[2].kind === Inline && !isconstant(args[2])) || return nothing
        bc = const_value(fc, true)
        for a in args[3:end]
            if a.typ === Bool
                bc = a
            elseif !(isconstant(a) && constant_value(a) === :not_atomic)
                return nothing
            end
        end
        return emit_getfield_unknownidx(fc, x, T, args[2], bc, rt)
    end
    # an explicit order: the plain access of a non-atomic field, or the atomic load of an
    # atomic one (mismatches are the runtime's ConcurrencyViolationError)
    order = :not_atomic
    for a in args[3:end]
        a.typ === Bool && continue
        (isconstant(a) && constant_value(a) isa Symbol) || return nothing
        order = constant_value(a)
    end
    if ismutabletype(T) && Base.isfieldatomic(T, i)
        order === :not_atomic && return nothing
        return emit_atomic_getfield(fc, x, T, i, order, rt)
    end
    order === :not_atomic || return nothing
    FT = fieldtype(T, i)
    b = fc.builder
    if x.kind === Ghost
        return const_value(fc, getfield(constant_value(x), i))
    elseif x.kind === Inline
        lay = layout(fc, T)
        idx = lay.fieldidx[i]
        idx < 0 && return convert_repr(fc, ghost(FT, something(ghost_value(FT))), rt)
        v = extract_field(fc, lay, x.V, idx)
        if lay.storage[i] === FieldInline
            maybe_undef_field(T, i) && has_references(FT) &&
                undef_check!(fc, first(reference_values(fc, v, FT)))
            return convert_repr(fc, inline(FT, v), rt)
        end
        maybe_undef_field(T, i) && undef_check!(fc, v)
        return convert_repr(fc, boxed(FT, v), rt)
    elseif x.kind === Boxed
        s = field_storage(T, i)
        s === FieldGhost && return convert_repr(fc, ghost(FT, something(ghost_value(FT))), rt)
        s === FieldBlob && return nothing
        addr = field_address(fc, x.V, T, i)
        s === FieldUnion && return convert_repr(fc, load_union_field(fc, addr, T, FT), rt)
        tb = field_tbaa(fc, T)
        if s === FieldInline
            if maybe_undef_field(T, i) && has_references(FT)
                pa = LLVM.inbounds_gep!(b, LLVM.Int8Type(), addr, [iptr(fc, first(reference_offsets(FT)))])
                undef_check!(fc, tbaa!(fc, LLVM.load!(b, T_tracked(), pa; align=config(fc).target.pointer_size), tb))
            end
            v = LLVM.load!(b, value_type(fc, FT), addr; align=field_alignment(fc, T, FT))
            return convert_repr(fc, inline(FT, tbaa!(fc, v, tb)), rt)
        end
        p = tbaa!(fc, LLVM.load!(b, T_tracked(), addr; align=config(fc).target.pointer_size), tb)
        maybe_undef_field(T, i) && undef_check!(fc, p)
        # an immutable object's references never change: they need no root of their own
        return convert_repr(fc, boxed(FT, p), rt)
    end
    return nothing
end

# `getfield(x, i)` of the field whose index `i` (an `Int`) is only known at run time,
# with the bounds check of the boundscheck argument `bc` (native code's
# `emit_getfield_unknownidx`): of the fields of an inline tuple of a single type, or of an
# object whose fields are all references or all of a single type
function emit_getfield_unknownidx(fc::FnCtx, x::CGVal, @nospecialize(T), idx::CGVal, bc::CGVal,
                                  @nospecialize(rt))
    n = fieldcount(T)
    n == 0 && return nothing
    b = fc.builder
    types = fieldtypes(T)
    FT = types[1]
    same = all(t -> t === FT, types)
    if n == 1
        lowered = fc -> emit_getfield(fc, CGVal[x, const_value(fc, 1)], rt)
    elseif x.kind === Ghost || (same && repr_kind(FT) === Ghost)
        same || return nothing
        lowered = fc -> convert_repr(fc, ghost(FT, something(ghost_value(FT))), rt)
    elseif x.kind === Inline
        lay = layout(fc, T)
        (lay.llvm isa LLVM.ArrayType || lay.llvm isa LLVM.VectorType) || return nothing
        # (references, of any types, or values of a single type)
        refs = all(i -> field_storage(T, i) === FieldPointer, 1:n)
        (refs || same) || return nothing
        lowered = fc -> begin
            v = inline_element(fc, x, lay, refs, n, idx; align=Base.datatype_alignment(FT))
            convert_repr(fc, refs ? boxed(Union{types...}, v) : inline(FT, v), rt)
        end
    elseif x.kind === Boxed
        ismutabletype(T) && T.name.atomicfields != C_NULL && return nothing
        storage = [field_storage(T, i) for i in 1:n]
        if all(==(FieldPointer), storage)
            lowered = fc -> begin
                p = LLVM.inbounds_gep!(b, T_tracked(), derived(fc, x.V), [LLVM.sub!(b, idx.V, iptr(fc, 1))])
                v = tbaa!(fc, LLVM.load!(b, T_tracked(), p; align=config(fc).target.pointer_size), field_tbaa(fc, T))
                any(i -> maybe_undef_field(T, i), 1:n) && undef_check!(fc, v)
                convert_repr(fc, boxed(Union{types...}, v), rt)
            end
        elseif same && all(==(FieldInline), storage) &&
               !(has_references(FT) && any(i -> maybe_undef_field(T, i), 1:n))
            stride = fieldoffset(T, 2) - fieldoffset(T, 1)
            lowered = fc -> begin
                off = LLVM.mul!(b, LLVM.sub!(b, idx.V, iptr(fc, 1)), iptr(fc, stride))
                p = LLVM.inbounds_gep!(b, LLVM.Int8Type(), derived(fc, x.V), [off])
                v = LLVM.load!(b, value_type(fc, FT), p; align=field_alignment(fc, T, FT))
                convert_repr(fc, inline(FT, tbaa!(fc, v, field_tbaa(fc, T))), rt)
            end
        else
            return nothing
        end
    else
        return nothing
    end
    bounds_check!(fc, LLVM.sub!(b, idx.V, iptr(fc, 1)), iptr(fc, n), bc, x, idx; unboxed=true)
    return lowered(fc)
end

# the element `idx` (1-based, in bounds) of the inline tuple `x` with the layout `lay` (an
# LLVM array or vector of `n` elements, references if `refs`, aligned to `align`):
# extracted from a vector, selected among references or a few values not in memory, or
# loaded from memory (the memory it was loaded from; for a constant, a private global, as
# native code's `value_to_pointer`; or a stack slot)
function inline_element(fc::FnCtx, x::CGVal, lay::Layout, refs::Bool, n::Int, idx::CGVal;
                        align::Integer)
    b = fc.builder
    i0 = LLVM.sub!(b, idx.V, iptr(fc, 1))
    if lay.llvm isa LLVM.VectorType
        return LLVM.extract_element!(b, x.V, LLVM.trunc!(b, i0, LLVM.Int32Type()))
    elseif refs || has_references(x.typ) ||
           (n <= 3 && x.mem === nothing && !(isconstant(x) && x.V isa LLVM.Constant))
        v = LLVM.extract_value!(b, x.V, 0)
        for i in 1:n-1
            c = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, i0, iptr(fc, i))
            v = LLVM.select!(b, c, LLVM.extract_value!(b, x.V, i), v)
        end
        return v
    end
    if x.mem !== nothing
        mem, tb = x.mem, :const
    elseif isconstant(x) && x.V isa LLVM.Constant
        mem, tb = constant_memory!(fc.cgm, x.V, Base.datatype_alignment(x.typ)), :const
    else
        mem, tb = entry_alloca!(fc, lay.llvm; align=Base.datatype_alignment(x.typ)), :stack
        tbaa!(fc, LLVM.store!(b, x.V, mem), :stack)
    end
    et = LLVM.element_type(lay.llvm)
    p = LLVM.inbounds_gep!(b, et, mem, [i0])
    return tbaa!(fc, LLVM.load!(b, et, p; align), tb)
end

# `setfield!(x, f, v, [order])` of a non-atomic field
function emit_setfield!(fc::FnCtx, args::Vector{CGVal})
    length(args) in (3, 4) || return nothing
    x = args[1]
    T = x.typ
    (T isa DataType && isconcretetype(T) && ismutabletype(T) && x.kind === Boxed) || return nothing
    i = field_index(T, args[2])
    (i === nothing || isconst(T, i) || Base.isfieldatomic(T, i)) && return nothing
    args[3].typ <: fieldtype(T, i) || return nothing
    if length(args) == 4
        (isconstant(args[4]) && constant_value(args[4]) === :not_atomic) || return nothing
    end
    emit_store_field!(fc, x.V, T, i, args[3]; barrier=true) || return nothing
    return args[3]
end

## the builtins

# builtins without side effects that are folded when their arguments are constants (if
# they throw, the call is left to the runtime, which throws)
const FOLDABLE = Any[Core.apply_type, Core.fieldtype, (<:), Core.typeof, Core.isa,
                     Core.nfields, Core.sizeof, Core.:(===), Core.tuple]

function fold_builtin(fc::FnCtx, @nospecialize(f), args::Vector{CGVal})
    v = try
        f(map(constant_value, args)...)
    catch err
        err isa Exception || rethrow()
        return nothing
    end
    return const_value(fc, v)
end

function emit_ifelse(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) == 3 && args[1].typ === Bool && args[1].kind === Inline) || return nothing
    k = repr_kind(rt)
    k === Ghost && return ghost(rt, something(ghost_value(rt)))
    k in (Inline, Boxed, UnionVal) || return nothing
    x, y = convert_repr(fc, args[2], rt), convert_repr(fc, args[3], rt)
    c = LLVM.trunc!(fc.builder, args[1].V, LLVM.Int1Type())
    return CGVal(rt, k, LLVM.select!(fc.builder, c, x.V, y.V), nothing, nothing)
end

function emit_typeof(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    length(args) == 1 || return nothing
    T = args[1].typ
    isconcretetype(T) && !iskind(T) && return const_value(fc, T)
    args[1].kind === UnionVal &&
        return convert_repr(fc, boxed(DataType, union_typeof(fc, args[1])), rt)
    args[1].kind === Boxed || return nothing
    return convert_repr(fc, boxed(DataType, typeof_box(fc, args[1].V)), rt)
end

function emit_isa_builtin(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) == 2 && isconstant(args[2])) || return nothing
    c = emit_isa(fc, args[1], constant_value(args[2]))
    c === nothing && return nothing
    c isa LLVM.ConstantInt && return const_value(fc, convert(Bool, c))
    return bool_value(fc, c)
end

function emit_typeassert(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) == 2 && isconstant(args[2])) || return nothing
    x, T = args[1], constant_value(args[2])
    x.typ <: T && return x
    c = emit_isa(fc, x, T)
    c === nothing && return nothing
    # on failure, the builtin itself throws the TypeError
    b = fc.builder
    fail = LLVM.BasicBlock(current_function(fc), "typeassert_fail")
    pass = LLVM.BasicBlock(current_function(fc), "typeassert_pass")
    LLVM.br!(b, c, pass, fail)
    LLVM.position!(b, LLVM.at_end(fail))
    emit_dynamic_call_raw(fc, const_value(fc, Core.typeassert), args)
    LLVM.unreachable!(b)
    LLVM.position!(b, LLVM.at_end(pass))
    typeintersect(x.typ, T) === Union{} && return emit_unreachable!(fc)
    return convert_repr(fc, boxed(Any, emit_box(fc, x)), rt)
end

function emit_throw(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    length(args) == 1 || return nothing
    b = fc.builder
    f = runtime_function(fc, :jl_throw)
    p = callee_rooted(fc, emit_box(fc, args[1]))
    LLVM.call!(b, LLVM.function_type(f), f, LLVM.Value[p])
    return emit_unreachable!(fc)
end

function emit_sizeof(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    length(args) == 1 || return nothing
    x = args[1]
    if x.typ === String && x.kind === Boxed
        len = LLVM.load!(fc.builder, iptr_type(fc), derived(fc, x.V); align=config(fc).target.pointer_size)
        return inline(Int, tbaa!(fc, len, :const))
    elseif x.typ isa DataType && x.typ <: GenericMemory && isconcretetype(x.typ) && x.kind === Boxed
        # the length times the size of an element (and its selector byte for unions)
        el = memory_elements(GenericMemoryRef{x.typ.parameters...})
        el === nothing && return nothing
        elsz = memory_elsize(GenericMemoryRef{x.typ.parameters...}) + (el[1] === :union ? 1 : 0)
        return inline(Int, LLVM.mul!(fc.builder, memory_length(fc, x.V), iptr(fc, elsz)))
    elseif x.typ isa DataType && isbitstype(x.typ)
        return const_value(fc, sizeof(x.typ))
    end
    return nothing
end

function emit_getglobal(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) == 2 && all(isconstant, args)) || return nothing
    m, s = constant_value(args[1]), constant_value(args[2])
    (m isa Module && s isa Symbol) || return nothing
    c = const_global(fc.cgm.world, m, s)
    c === nothing || return const_value(fc, something(c))
    # a global, through its binding
    ref = GlobalRef(m, s)
    direct_binding(fc, ref) === nothing && return nothing
    return convert_repr(fc, nonconst_global(fc, ref), rt)
end

# the atomic load with `order` of the atomic field `i` of the object `x` of type `T`: of a
# bits type of 1 to 8 bytes, or a reference
function emit_atomic_getfield(fc::FnCtx, x::CGVal, @nospecialize(T), i::Int, order::Symbol,
                              @nospecialize(rt))
    x.kind === Boxed || return nothing
    ord = atomic_ordering(order; load=true)
    ord === nothing && return nothing
    FT = fieldtype(T, i)
    s = field_storage(T, i)
    b = fc.builder
    if s === FieldPointer
        ty, W = T_tracked(), config(fc).target.pointer_size
    elseif s === FieldInline && isbitstype(FT) && sizeof(FT) in (1, 2, 4, 8) && repr_kind(FT) === Inline
        ty, W = LLVM.IntType(8 * sizeof(FT)), sizeof(FT)
    else
        return nothing
    end
    v = LLVM.load!(b, ty, field_address(fc, x.V, T, i))
    LLVM.ordering!(v, ord)
    LLVM.alignment!(v, W)
    tbaa!(fc, v, field_tbaa(fc, T))
    if s === FieldPointer
        maybe_undef_field(T, i) && undef_check!(fc, v)
        return convert_repr(fc, boxed(FT, v), rt)
    end
    return convert_repr(fc, inline(FT, llvmcall_value(fc, v, value_type(fc, FT))), rt)
end

@noinline throw_modify_type(@nospecialize(T), @nospecialize(x)) =
    throw(TypeError(:modifyfield!, "", T, x))

"""
    JuliaCodegen.emit_invoke_modify(fc, ex, typ) -> CGVal

`Expr(:invoke_modify, ci, modifyfield!, obj, field, op, x, order)`: `modifyfield!` with
the operation `op` known to be the CodeInstance `ci`. For an atomic field of a bits type of
1 to 8 bytes, or of a reference, a loop of the atomic compare-and-exchange of the field
with `op(old, x)`, as native code does; otherwise, the call of `modifyfield!`.
"""
function emit_invoke_modify(fc::FnCtx, ex::Expr, @nospecialize(typ))
    args = CGVal[operand(fc, a) for a in ex.args[2:end]]
    any(a -> a.kind === Bottom, args) && return bottom()
    # (the operation's result type, of its CodeInstance)
    opt = ex.args[1] isa Core.CodeInstance ? ex.args[1].rettype : Any
    r = length(args) == 6 ? emit_modify_loop(fc, invoke_target(ex.args[1]), opt, args, typ) : nothing
    r === nothing || return r
    return emit_dynamic_call(fc, args[1], args[2:end], typ)
end

function emit_modify_loop(fc::FnCtx, mi::Core.MethodInstance, @nospecialize(opt),
                          args::Vector{CGVal}, @nospecialize(typ))
    _, obj, fld, op, x, ord = args
    T = obj.typ
    (obj.kind === Boxed && T isa DataType && ismutabletype(T) && isconcretetype(T)) || return nothing
    i = field_index(T, fld)
    (i !== nothing && isconstant(ord) && constant_value(ord) isa Symbol) || return nothing
    Base.isfieldatomic(T, i) || return nothing
    order = constant_value(ord)
    success = atomic_ordering(order; load=true)
    (success === nothing || order in (:not_atomic, :unordered)) && return nothing
    FT = fieldtype(T, i)
    # (a result that can't be stored: the runtime's TypeError)
    typeintersect(opt, FT) === Union{} && return nothing
    s = field_storage(T, i)
    b = fc.builder
    isref = s === FieldPointer
    if isref
        ity = T_tracked()
    elseif s === FieldInline && isbitstype(FT) && sizeof(FT) in (1, 2, 4, 8) && repr_kind(FT) === Inline
        ity = LLVM.IntType(8 * sizeof(FT))
    else
        return nothing
    end
    W = isref ? config(fc).target.pointer_size : sizeof(FT)
    addr = field_address(fc, obj.V, T, i)
    value_of(v) = isref ? boxed(FT, v) : inline(FT, llvmcall_value(fc, v, value_type(fc, FT)))
    bits_of(v::CGVal) = isref ? emit_box(fc, v) : llvmcall_value(fc, convert_repr(fc, v, FT).V, ity)
    init = LLVM.load!(b, ity, addr)
    LLVM.ordering!(init, LLVM.API.LLVMAtomicOrderingMonotonic)
    LLVM.alignment!(init, W)
    tbaa!(fc, init, field_tbaa(fc, T))
    f = current_function(fc)
    from = current_block(b)
    loop = LLVM.BasicBlock(f, "xchg")
    done = LLVM.BasicBlock(f, "done_xchg")
    LLVM.br!(b, loop)
    LLVM.position!(b, LLVM.at_end(loop))
    old = LLVM.phi!(b, ity)
    # (a reference field may be undefined: UndefRefError)
    isref && undef_check!(fc, old)
    oldv = value_of(old)
    # the new value: `op(old, x)`, of the field's type
    newv = emit_invoke_call(fc, mi, CGVal[op, oldv, x], opt)
    newv.kind === Bottom && return newv
    if !(newv.typ <: FT)
        ok = emit_isa(fc, newv, FT)
        ok === nothing && return nothing
        emit_guard!(fc, ok, throw_modify_type, const_value(fc, FT), newv)
    end
    newbits = bits_of(newv)
    r = LLVM.atomic_cmpxchg!(b, addr, old, newbits, success, LLVM.API.LLVMAtomicOrderingMonotonic;
                             align=W)
    tbaa!(fc, r, field_tbaa(fc, T))
    loaded = LLVM.extract_value!(b, r, 0)
    ok = LLVM.extract_value!(b, r, 1)
    tail = current_block(b)
    append!(LLVM.incoming(old), [(init, from), (loaded, tail)])
    LLVM.br!(b, ok, done, loop)
    LLVM.position!(b, LLVM.at_end(done))
    isref && write_barrier!(b, fc.cgm.mod, dialect(fc), obj.V, LLVM.addrspacecast!(b, addr, T_derived()), newbits)
    newfinal = isref ? boxed(FT, newbits) : value_of(newbits)
    P = Pair{FT,FT}
    pair = repr_kind(P) === Inline ? emit_new_inline(fc, P, CGVal[oldv, newfinal]) : nothing
    pair === nothing && return nothing
    return convert_repr(fc, pair, typ)
end

# `setglobal!(m, s, x, [order])` of a global of type `Any` with the default (release) order,
# through its binding
function emit_setglobal!(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) in (3, 4) && isconstant(args[1]) && isconstant(args[2])) || return nothing
    length(args) == 4 && !(isconstant(args[4]) && constant_value(args[4]) === :release) &&
        return nothing
    m, s = constant_value(args[1]), constant_value(args[2])
    (m isa Module && s isa Symbol) || return nothing
    emit_binding_assignment!(fc, GlobalRef(m, s), args[3]) || return nothing
    return convert_repr(fc, args[3], rt)
end

# `isdefined(x, field)` with a constant field of a concrete type
function emit_isdefined(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) == 2 && isconstant(args[2])) || return nothing
    x = args[1]
    T = x.typ
    (T isa DataType && isconcretetype(T) && !(T <: Module)) || return nothing
    i = field_index(T, args[2])
    i === nothing && return (constant_value(args[2]) isa Union{Symbol,Int} ? const_value(fc, false) : nothing)
    maybe_undef_field(T, i) || return const_value(fc, true)
    s = field_storage(T, i)
    if s === FieldPointer && x.kind === Boxed && !(ismutabletype(T) && Base.isfieldatomic(T, i))
        p = LLVM.load!(fc.builder, T_tracked(), field_address(fc, x.V, T, i);
                       align=config(fc).target.pointer_size)
        return bool_value(fc, nonnull(fc, tbaa!(fc, p, field_tbaa(fc, T))))
    end
    # an inline field without references is always defined
    s in (FieldInline, FieldGhost) && !has_references(fieldtype(T, i)) && return const_value(fc, true)
    return nothing
end

# `Core.svec(xs...)`: allocated inline, as native code (from Julia 1.12 on), with the
# elements boxed first
function emit_svec(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    isempty(args) && return const_value(fc, Core.svec())
    b = fc.builder
    W = config(fc).target.pointer_size
    elems = LLVM.Value[emit_box(fc, a) for a in args]
    sv = call_op!(fc, "julia.gc_alloc_obj", fc.current_task,
                  LLVM.ConstantInt(LLVM.Int64Type(), W * (length(args) + 1)),
                  type_tag(fc, Core.SimpleVector))
    data = derived(fc, sv)
    LLVM.store!(b, iptr(fc, length(args)), data; align=W)
    for (i, e) in enumerate(elems)
        addr = LLVM.inbounds_gep!(b, LLVM.Int8Type(), data, [iptr(fc, W * i)])
        st = LLVM.store!(b, e, addr; align=W)
        LLVM.ordering!(st, LLVM.API.LLVMAtomicOrderingRelease)
        write_barrier!(b, fc.cgm.mod, dialect(fc), sv, addr, e)
    end
    return boxed(Core.SimpleVector, sv)
end

# `Core._svec_len(sv)`: the length, the first word
function emit_svec_len(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    length(args) == 1 || return nothing
    sv = args[1]
    isconstant(sv) && constant_value(sv) isa Core.SimpleVector &&
        return const_value(fc, length(constant_value(sv)))
    sv.typ === Core.SimpleVector || return nothing
    W = config(fc).target.pointer_size
    return inline(Int, LLVM.load!(fc.builder, iptr_type(fc), derived(fc, emit_box(fc, sv)); align=W))
end

const BUILTINS = IdDict{Any,Function}(
    Core.:(===) => (fc, args, rt) -> length(args) == 2 ? emit_egal(fc, args[1], args[2]) : nothing,
    Core.ifelse => emit_ifelse,
    Core.typeof => emit_typeof,
    Core.isa => emit_isa_builtin,
    Core.typeassert => emit_typeassert,
    Core.tuple => (fc, args, rt) -> repr_kind(rt) === Inline ? emit_new_inline(fc, rt, args) : nothing,
    Core.getfield => emit_getfield,
    Core.setfield! => (fc, args, rt) -> emit_setfield!(fc, args),
    Core.isdefined => emit_isdefined,
    Core.throw => emit_throw,
    Core.sizeof => emit_sizeof,
    Core.getglobal => emit_getglobal,
    Core.setglobal! => emit_setglobal!,
    Core.svec => emit_svec,
    Core._svec_len => emit_svec_len,
)

"""
    JuliaCodegen.emit_builtin(fc, f, args, rt) -> Union{CGVal,Nothing}

The call of the builtin `f` with `args`, of result type `rt`, or `nothing` if it is left
to the runtime.
"""
function emit_builtin(fc::FnCtx, @nospecialize(f), args::Vector{CGVal}, @nospecialize(rt))
    if any(x -> x === f, FOLDABLE) && all(isconstant, args)
        r = fold_builtin(fc, f, args)
        r === nothing || return r
    end
    emitter = get(BUILTINS, f, nothing)
    emitter === nothing && return nothing
    return emitter(fc, args, rt)
end
