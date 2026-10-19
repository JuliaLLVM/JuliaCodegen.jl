# The memory builtins: `memorynew`, `memoryrefnew`, `memoryrefget`, `memoryrefset!`,
# `memoryrefunset!`, `memoryrefoffset`. A `GenericMemoryRef{:not_atomic, T, Core.CPU}` is
# the inline struct `{ptr ptr_or_offset, ptr addrspace(10) mem}`, and a `GenericMemory`
# object starts with `length::Int, ptr::Ptr{Cvoid}`. Elements are stored inline (isbits,
# or with references), as references, or as isbits unions (payloads, then a selector byte
# per element; a reference's `ptr_or_offset` is the element index).

# the TBAA of memory contents: isbits data, references, union selectors
function memory_tbaa(fc::FnCtx, kind::Symbol)
    new = dialect(fc).minor >= v"1.14"
    kind === :data && return new ? :field : :arraybuf
    kind === :refs && return new ? :ptrmemorybuf : :ptrarraybuf
    return new ? :memoryselbyte : :arrayselbyte
end

"""
    JuliaCodegen.memory_elements(R) -> Union{Nothing,Tuple{Symbol,Any}}

How the elements of a memory reference type `R` are stored: `(:bits, T)` inline without
references, `(:inline, T)` inline with references, `(:refs, T)` as references,
`(:union, U)` as an isbits union; `nothing` for references this doesn't lower (atomic,
or of another address space).
"""
function memory_elements(@nospecialize R)
    (R isa DataType && R <: GenericMemoryRef) || return nothing
    (R.parameters[1] === :not_atomic && R.parameters[3] === Core.CPU) || return nothing
    T = R.parameters[2]
    T isa Union && is_bits_union(T) && return (:union, T)
    Base.allocatedinline(T) || return (:refs, T)
    (T isa DataType && isconcretetype(T) && sizeof(T) > 0 && repr_kind(T) === Inline) ||
        return nothing
    return (has_references(T) ? :inline : :bits, T)
end

# the size of an element in memory (`jl_datatype_layout_t.size` of the memory type)
memory_elsize(@nospecialize R) =
    Int(unsafe_load(Ptr{Base.DataTypeLayout}(
        GenericMemory{R.parameters[1], R.parameters[2], R.parameters[3]}.layout)).size)

@noinline throw_boundserror(a, i) = throw(BoundsError(a, i))

memory_length(fc::FnCtx, mem::LLVM.Value) =
    tbaa!(fc, LLVM.load!(fc.builder, iptr_type(fc), derived(fc, mem); align=config(fc).target.pointer_size),
          :memorylen)

function memory_data(fc::FnCtx, mem::LLVM.Value)
    b = fc.builder
    p = LLVM.inbounds_gep!(b, LLVM.Int8Type(), derived(fc, mem), [iptr(fc, config(fc).target.pointer_size)])
    return tbaa!(fc, LLVM.load!(b, T_ptr(), p; align=config(fc).target.pointer_size), :memoryptr)
end

"`julia.gc_loaded(mem, p)`: the pointer `p` into the memory `mem`, which keeps it alive."
emit_gc_loaded(fc::FnCtx, mem::LLVM.Value, p::LLVM.Value) = call_op!(fc, "julia.gc_loaded", mem, p)

# the object the write barrier of a store into the memory `mem` is for: the memory, or
# the object that owns its data (`emit_genericmemoryowner`)
function memory_owner(fc::FnCtx, mem::LLVM.Value)
    b = fc.builder
    W = config(fc).target.pointer_size
    data = memory_data(fc, mem)
    inline_data = LLVM.inbounds_gep!(b, LLVM.Int8Type(), derived(fc, mem), [iptr(fc, 2W)])
    foreign = LLVM.icmp!(b, LLVM.API.LLVMIntNE, inline_data, LLVM.addrspacecast!(b, data, T_derived()))
    return emit_if(fc, foreign, T_tracked(); name="memory_owner", otherwise=mem) do
        owner = tbaa!(fc, LLVM.load!(b, T_tracked(), inline_data; align=W), :memoryptr)
        LLVM.select!(b, LLVM.icmp!(b, LLVM.API.LLVMIntEQ, owner, LLVM.null(T_tracked())), mem, owner)
    end
end

# a bounds check of the 0-based index `i0` against the length `len`, unless the
# boundscheck argument `bc` is false
function bounds_check!(fc::FnCtx, i0::LLVM.Value, len::LLVM.Value, bc::CGVal, x::CGVal, idx::CGVal)
    (isconstant(bc) && constant_value(bc) === false) && return
    b = fc.builder
    inb = LLVM.icmp!(b, LLVM.API.LLVMIntULT, i0, len)
    isconstant(bc) || (inb = LLVM.or!(b, inb, LLVM.not!(b, LLVM.trunc!(b, bc.V, LLVM.Int1Type()))))
    emit_guard!(fc, inb, throw_boundserror, x, idx)
end

function emit_memoryrefnew(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    b = fc.builder
    if length(args) == 1
        # a reference to the first element
        (args[1].typ isa DataType && args[1].typ <: GenericMemory && args[1].kind === Boxed) || return nothing
        el = memory_elements(rt)
        el === nothing && return nothing
        mem = args[1].V
        first = el[1] === :union ? LLVM.null(T_ptr()) : memory_data(fc, mem)
        lay = layout(fc, rt)
        agg = insert_field(fc, lay, LLVM.UndefValue(lay.llvm), first, 0)
        return inline(rt, insert_field(fc, lay, agg, mem, 1))
    end
    length(args) == 3 || return nothing
    x, idx, bc = args
    (idx.typ === Int && idx.kind === Inline) || return nothing
    if x.typ isa DataType && x.typ <: GenericMemory
        # `memoryrefnew(mem, i, boundscheck)`
        x.kind === Boxed || return nothing
        base = emit_memoryrefnew(fc, CGVal[x], rt)
        base === nothing && return nothing
        bounds_check!(fc, LLVM.sub!(b, idx.V, iptr(fc, 1)), memory_length(fc, x.V), bc, x, idx)
        return emit_memoryrefnew(fc, CGVal[base, idx, const_value(fc, false)], rt)
    end
    # `memoryrefnew(ref, i, boundscheck)`: the reference i-1 elements further
    el = memory_elements(x.typ)
    (el !== nothing && x.kind === Inline) || return nothing
    lay = layout(fc, x.typ)
    p = extract_field(fc, lay, x.V, 0)
    mem = extract_field(fc, lay, x.V, 1)
    i0 = LLVM.sub!(b, idx.V, iptr(fc, 1))
    if el[1] === :union
        off = LLVM.add!(b, LLVM.ptrtoint!(b, p, iptr_type(fc)), i0)
        bounds_check!(fc, off, memory_length(fc, mem), bc, x, idx)
        return inline(x.typ, insert_field(fc, lay, x.V, LLVM.inttoptr!(b, off, T_ptr()), 0))
    end
    elsz = el[1] === :refs ? config(fc).target.pointer_size : Base.aligned_sizeof(el[2])
    newp = LLVM.inbounds_gep!(b, LLVM.Int8Type(), p, [LLVM.mul!(b, i0, iptr(fc, elsz))])
    if !(isconstant(bc) && constant_value(bc) === false)
        # (newp - mem.ptr) / elsz < mem.length, unsigned
        diff = LLVM.sub!(b, LLVM.ptrtoint!(b, newp, iptr_type(fc)),
                         LLVM.ptrtoint!(b, memory_data(fc, mem), iptr_type(fc)))
        bounds_check!(fc, LLVM.udiv!(b, diff, iptr(fc, elsz)), memory_length(fc, mem), bc, x, idx)
    end
    return inline(x.typ, insert_field(fc, lay, x.V, newp, 0))
end

# the address of the element a (non-union) memory reference refers to, tied to its memory
# with `julia.gc_loaded`
function memref_address(fc::FnCtx, ref::CGVal)
    lay = layout(fc, ref.typ)
    p = extract_field(fc, lay, ref.V, 0)
    return emit_gc_loaded(fc, extract_field(fc, lay, ref.V, 1), p)
end

# the payload and selector addresses of the element a union memory reference refers to
function union_memref_addresses(fc::FnCtx, ref::CGVal)
    b = fc.builder
    lay = layout(fc, ref.typ)
    elsz = memory_elsize(ref.typ)
    mem = extract_field(fc, lay, ref.V, 1)
    off = LLVM.ptrtoint!(b, extract_field(fc, lay, ref.V, 0), iptr_type(fc))
    data = emit_gc_loaded(fc, mem, memory_data(fc, mem))
    payload = LLVM.inbounds_gep!(b, LLVM.Int8Type(), data, [LLVM.mul!(b, off, iptr(fc, elsz))])
    sel = LLVM.inbounds_gep!(b, LLVM.Int8Type(), data,
                             [LLVM.add!(b, LLVM.mul!(b, memory_length(fc, mem), iptr(fc, elsz)), off)])
    return payload, sel
end

not_atomic(v::CGVal) = isconstant(v) && constant_value(v) === :not_atomic

# `memoryrefget(ref, order, boundscheck)`
function emit_memoryrefget(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    length(args) == 3 || return nothing
    ref = args[1]
    el = memory_elements(ref.typ)
    (el !== nothing && ref.kind === Inline && not_atomic(args[2])) || return nothing
    kind, T = el
    b = fc.builder
    if kind === :union
        pp, sp = union_memref_addresses(fc, ref)
        N = union_payload_size(T)
        payload = N == 0 ? LLVM.UndefValue(LLVM.ArrayType(LLVM.Int8Type(), 0)) :
                  tbaa!(fc, LLVM.load!(b, LLVM.ArrayType(LLVM.Int8Type(), N), pp; align=1), memory_tbaa(fc, :data))
        sel = tbaa!(fc, LLVM.load!(b, LLVM.Int8Type(), sp), memory_tbaa(fc, :selector))
        return convert_repr(fc, make_union(fc, T, payload, LLVM.add!(b, sel, i8(1))), rt)
    end
    p = memref_address(fc, ref)
    if kind === :refs
        v = LLVM.load!(b, T_tracked(), p; align=config(fc).target.pointer_size)
        tbaa!(fc, v, memory_tbaa(fc, :refs))
        undef_check!(fc, v)      # an unassigned element is a null reference
        return convert_repr(fc, boxed(T, v), rt)
    end
    v = tbaa!(fc, LLVM.load!(b, value_type(fc, T), p; align=Base.datatype_alignment(T)), memory_tbaa(fc, :data))
    # an unassigned element with references has a null first reference
    kind === :inline && undef_check!(fc, first(reference_values(fc, v, T)))
    return convert_repr(fc, inline(T, v), rt)
end

# `memoryrefset!(ref, x, order, boundscheck)`
function emit_memoryrefset!(fc::FnCtx, args::Vector{CGVal})
    length(args) == 4 || return nothing
    ref, x = args[1], args[2]
    el = memory_elements(ref.typ)
    (el !== nothing && ref.kind === Inline && not_atomic(args[3])) || return nothing
    kind, T = el
    x.typ <: T || return nothing
    b = fc.builder
    if kind === :union
        v = convert_repr(fc, x, T)
        pp, sp = union_memref_addresses(fc, ref)
        union_payload_size(T) == 0 ||
            tbaa!(fc, LLVM.store!(b, union_payload_value(fc, v), pp; align=1), memory_tbaa(fc, :data))
        tbaa!(fc, LLVM.store!(b, LLVM.sub!(b, union_tindex_value(fc, v), i8(1)), sp), memory_tbaa(fc, :selector))
        return x
    end
    lay = layout(fc, ref.typ)
    mem = extract_field(fc, lay, ref.V, 1)
    if kind === :refs
        v = emit_box(fc, x)
        owner = memory_owner(fc, mem)
        p = memref_address(fc, ref)
        write_barrier!(b, fc.cgm.mod, dialect(fc), owner, p, v)
        tbaa!(fc, LLVM.store!(b, v, p; align=config(fc).target.pointer_size), memory_tbaa(fc, :refs))
        return x
    end
    v = convert_repr(fc, x, T)
    if kind === :inline
        owner = memory_owner(fc, mem)
        p = memref_address(fc, ref)
        fields = LLVM.Value[LLVM.inbounds_gep!(b, LLVM.Int8Type(), p, [iptr(fc, o)]) for o in reference_offsets(T)]
        write_barrier!(b, fc.cgm.mod, dialect(fc), owner, fields, reference_values(fc, v.V, T))
    else
        p = memref_address(fc, ref)
    end
    tbaa!(fc, LLVM.store!(b, v.V, p; align=Base.datatype_alignment(T)), memory_tbaa(fc, :data))
    return x
end

# `memoryrefunset!(ref, order, boundscheck)`: a no-op for elements without references,
# a null store (with its barrier, as native code) for references
function emit_memoryrefunset!(fc::FnCtx, args::Vector{CGVal})
    length(args) == 3 || return nothing
    ref = args[1]
    el = memory_elements(ref.typ)
    (el !== nothing && ref.kind === Inline && not_atomic(args[2])) || return nothing
    kind, T = el
    kind in (:union, :bits) && return const_value(fc, nothing)
    kind === :refs || return nothing
    b = fc.builder
    mem = extract_field(fc, layout(fc, ref.typ), ref.V, 1)
    owner = memory_owner(fc, mem)
    p = memref_address(fc, ref)
    null = LLVM.null(T_tracked())
    write_barrier!(b, fc.cgm.mod, dialect(fc), owner, p, null)
    st = LLVM.store!(b, null, p; align=config(fc).target.pointer_size,
                     ordering=LLVM.API.LLVMAtomicOrderingRelease)
    tbaa!(fc, st, memory_tbaa(fc, :refs))
    return const_value(fc, nothing)
end

# `memoryrefoffset(ref)`: the 1-based index of the element
function emit_memoryrefoffset(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) == 1 && args[1].kind === Inline) || return nothing
    ref = args[1]
    el = memory_elements(ref.typ)
    el === nothing && return nothing
    b = fc.builder
    lay = layout(fc, ref.typ)
    p = LLVM.ptrtoint!(b, extract_field(fc, lay, ref.V, 0), iptr_type(fc))
    off = if el[1] === :union
        p
    else
        elsz = el[1] === :refs ? config(fc).target.pointer_size : Base.aligned_sizeof(el[2])
        base = LLVM.ptrtoint!(b, memory_data(fc, extract_field(fc, lay, ref.V, 1)), iptr_type(fc))
        LLVM.udiv!(b, LLVM.sub!(b, p, base), iptr(fc, elsz))
    end
    return inline(Int, LLVM.add!(b, off, iptr(fc, 1)))
end

# `memorynew(M, n)`, by the runtime's allocator
function emit_memorynew(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    (length(args) == 2 && isconstant(args[1]) && args[2].typ === Int && args[2].kind === Inline) ||
        return nothing
    M = constant_value(args[1])
    (M isa DataType && M <: GenericMemory && isconcretetype(M)) || return nothing
    f = runtime_function(fc, :jl_alloc_genericmemory)
    return boxed(M, LLVM.call!(fc.builder, LLVM.function_type(f), f, LLVM.Value[literal_pointer(fc, M), args[2].V]))
end

# (`memoryrefunset!` exists from Julia 1.13 on)
for (name, emitter) in ((:memoryrefnew, emit_memoryrefnew), (:memoryrefget, emit_memoryrefget),
                        (:memoryrefset!, (fc, args, rt) -> emit_memoryrefset!(fc, args)),
                        (:memoryrefunset!, (fc, args, rt) -> emit_memoryrefunset!(fc, args)),
                        (:memoryrefoffset, emit_memoryrefoffset), (:memorynew, emit_memorynew))
    isdefined(Core, name) && (BUILTINS[getfield(Core, name)] = emitter)
end
