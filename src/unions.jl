# Unboxed unions ("union splitting" of values): the `TIndex` representation of
# `jl_cgval_t`, as an SSA value (see `union_type`). A member's bytes, with its references
# left out, are in the payload; its references, in the order of their offsets, are the
# roots (a split value, as native code passes aggregates with references).

i8(x::Integer) = LLVM.ConstantInt(LLVM.Int8Type(), x)

# store the inline value `v` of type `T` as a split value: its bytes at `bits + off` (with
# the references left out, unless `roots` is `nothing`), and its references pushed to
# `roots`
function split_store!(fc::FnCtx, v::LLVM.Value, @nospecialize(T), bits::Union{Nothing,LLVM.Value},
                      roots::Union{Nothing,Vector{LLVM.Value}}, off::Int=0)
    b = fc.builder
    if isprimitivetype(T)
        bits === nothing && return
        tbaa!(fc, LLVM.store!(b, v, LLVM.gep!(b, LLVM.Int8Type(), bits, [iptr(fc, off)])), :stack)
        return
    end
    lay = layout(fc, T)
    for i in 1:fieldcount(T)
        idx = lay.fieldidx[i]
        idx < 0 && continue
        fv = extract_field(fc, lay, v, idx)
        foff = off + Int(fieldoffset(T, i))
        if lay.storage[i] === FieldPointer
            if roots === nothing
                bits === nothing ||
                    tbaa!(fc, LLVM.store!(b, fv, LLVM.gep!(b, LLVM.Int8Type(), bits, [iptr(fc, foff)])), :stack)
            else
                push!(roots, fv)
            end
        else
            split_store!(fc, fv, fieldtype(T, i), bits, roots, foff)
        end
    end
end

# the inline value of type `T` stored as a split value (the inverse of `split_store!`)
function split_load(fc::FnCtx, @nospecialize(T), bits::Union{Nothing,LLVM.Value},
                    roots::Vector{LLVM.Value}, k::Base.RefValue{Int}=Ref(0), off::Int=0)
    b = fc.builder
    ty = value_type(fc, T)
    if isprimitivetype(T)
        return tbaa!(fc, LLVM.load!(b, ty, LLVM.gep!(b, LLVM.Int8Type(), bits, [iptr(fc, off)])), :stack)
    end
    lay = layout(fc, T)
    agg = LLVM.UndefValue(ty)
    for i in 1:fieldcount(T)
        idx = lay.fieldidx[i]
        idx < 0 && continue
        foff = off + Int(fieldoffset(T, i))
        fv = if lay.storage[i] === FieldPointer
            k[] += 1
            roots[k[]]
        else
            split_load(fc, fieldtype(T, i), bits, roots, k, foff)
        end
        agg = insert_field(fc, lay, agg, fv, idx)
    end
    return agg
end

# a stack slot for (at least) the payload of U
payload_slot(fc::FnCtx, @nospecialize(U), size::Int=union_payload_size(U)) =
    entry_alloca!(fc, LLVM.ArrayType(LLVM.Int8Type(), max(size, 1));
                  align=max(union_payload_align(U), 8))

# reinterpret through a stack slot: store `v`, load it back as `ty`
function stack_reinterpret(fc::FnCtx, v::LLVM.Value, ty::LLVM.LLVMType, align::Int)
    b = fc.builder
    dl = fc.cgm.layouts.datalayout
    size = max(LLVM.abi_size(dl, ty), LLVM.abi_size(dl, LLVM.value_type(v)), 1)
    slot = entry_alloca!(fc, LLVM.ArrayType(LLVM.Int8Type(), size); align=max(align, 8))
    tbaa!(fc, LLVM.store!(b, v, slot), :stack)
    return tbaa!(fc, LLVM.load!(b, ty, slot), :stack)
end

# the payload and roots of the value `v` (of the member type `v.typ`) in union U
function member_parts(fc::FnCtx, @nospecialize(U), v::CGVal)
    b = fc.builder
    N = union_payload_size(U)
    pty = LLVM.ArrayType(LLVM.Int8Type(), N)
    roots = LLVM.Value[]
    (v.kind === Ghost || v.kind === Bottom) && return LLVM.UndefValue(pty), roots
    M = v.typ
    if npointers(M) == 0
        N == 0 && return LLVM.UndefValue(pty), roots
        return stack_reinterpret(fc, v.V, pty, union_payload_align(U)), roots
    end
    if !in_payload(M) || N == 0
        split_store!(fc, v.V, M, nothing, roots)
        return LLVM.UndefValue(pty), roots
    end
    slot = payload_slot(fc, U, max(N, sizeof(M)))
    split_store!(fc, v.V, M, slot, roots)
    return tbaa!(fc, LLVM.load!(b, pty, slot), :stack), roots
end

"""
    JuliaCodegen.make_union(fc, U, payload, tindex, roots; box) -> CGVal

A value of the unboxed union `U` from its parts; `tindex` is the raw type index (with
`UNION_BOX_MARKER` when `box` is given).
"""
function make_union(fc::FnCtx, @nospecialize(U), payload::LLVM.Value, tindex::LLVM.Value,
                    roots::Vector{LLVM.Value}=LLVM.Value[]; box::Union{Nothing,LLVM.Value}=nothing)
    b = fc.builder
    agg = LLVM.UndefValue(union_type(U))
    agg = LLVM.insert_value!(b, agg, payload, 0)
    agg = LLVM.insert_value!(b, agg, tindex, 1)
    R = union_nroots(U)
    length(roots) <= R || unsupported(length(roots), " roots for the union ", U)
    for i in 1:R
        agg = LLVM.insert_value!(b, agg, i <= length(roots) ? roots[i] : LLVM.null(T_tracked()), 1 + i)
    end
    if union_has_box(U)
        agg = LLVM.insert_value!(b, agg, something(box, LLVM.null(T_tracked())), 2 + R)
    else
        box === nothing || unsupported("a box for the union ", U)
    end
    return unboxed_union(U, agg)
end

# a union value of a member that only lives boxed
boxed_union(fc::FnCtx, @nospecialize(U), box::LLVM.Value) =
    make_union(fc, U, LLVM.UndefValue(LLVM.ArrayType(LLVM.Int8Type(), union_payload_size(U))),
               i8(UNION_BOX_MARKER); box)

union_raw_tindex(fc::FnCtx, v::CGVal) = LLVM.extract_value!(fc.builder, v.V, 1)
"The type index of a union value (0 for a member that only lives boxed)."
function union_tindex_value(fc::FnCtx, v::CGVal)
    t = union_raw_tindex(fc, v)
    union_has_box(v.typ) || return t
    return LLVM.and!(fc.builder, t, i8(0x7f))
end
union_box_value(fc::FnCtx, v::CGVal) = LLVM.extract_value!(fc.builder, v.V, 2 + union_nroots(v.typ))
function union_isboxed(fc::FnCtx, v::CGVal)
    union_has_box(v.typ) || return i1(false)
    b = fc.builder
    return LLVM.icmp!(b, LLVM.API.LLVMIntNE, LLVM.and!(b, union_raw_tindex(fc, v), i8(UNION_BOX_MARKER)), i8(0))
end
union_payload_value(fc::FnCtx, v::CGVal) = LLVM.extract_value!(fc.builder, v.V, 0)
union_root_values(fc::FnCtx, v::CGVal, n::Int=union_nroots(v.typ)) =
    LLVM.Value[LLVM.extract_value!(fc.builder, v.V, 1 + i) for i in 1:n]

"The value of the member `M` of a union value known to hold an `M`."
function union_member(fc::FnCtx, v::CGVal, @nospecialize M)
    repr_kind(M) === Ghost && return ghost(M, something(ghost_value(M)))
    U = v.typ
    ty = value_type(fc, M)
    if npointers(M) == 0
        return inline(M, stack_reinterpret(fc, union_payload_value(fc, v), ty, union_payload_align(U)))
    end
    roots = union_root_values(fc, v, npointers(M))
    bits = nothing
    if in_payload(M) && union_payload_size(U) > 0
        bits = payload_slot(fc, U, max(union_payload_size(U), sizeof(M)))
        tbaa!(fc, LLVM.store!(fc.builder, union_payload_value(fc, v), bits), :stack)
    end
    return inline(M, split_load(fc, M, bits, roots))
end

"""
    JuliaCodegen.tindex_switch(body, fc, t, members, ty; name, default) -> LLVM.Value

`body(i, M)` for the member `M` selected by the type index `t` (an `i8`, from 1), each in
its own block, with the results (of LLVM type `ty`) merged by a phi; `default()` for any
other `t` (0: a member that only lives boxed), or `unreachable` without one.
"""
function tindex_switch(body, fc::FnCtx, t::LLVM.Value, ms, ty::LLVM.LLVMType;
                       name::String="union", default=nothing)
    b = fc.builder
    f = current_function(fc)
    done = LLVM.BasicBlock(f, "$(name)_done")
    dflt = LLVM.BasicBlock(f, default === nothing ? "$(name)_bad" : "$(name)_boxed")
    sw = LLVM.switch!(b, t, dflt, length(ms))
    incoming = Tuple{LLVM.Value,LLVM.BasicBlock}[]
    for (i, M) in enumerate(ms)
        bb = LLVM.BasicBlock(f, "$(name)_$i")
        LLVM.API.LLVMAddCase(sw, i8(i), bb)
        LLVM.position!(b, LLVM.at_end(bb))
        r = body(i, M)
        push!(incoming, (r, current_block(b)))
        LLVM.br!(b, done)
    end
    LLVM.position!(b, LLVM.at_end(dflt))
    if default === nothing
        LLVM.unreachable!(b)
    else
        push!(incoming, (default(), current_block(b)))
        LLVM.br!(b, done)
    end
    LLVM.position!(b, LLVM.at_end(done))
    phi = LLVM.phi!(b, ty)
    append!(LLVM.incoming(phi), incoming)
    return phi
end

# `body(M)` for each unboxed member M of a union value (`boxed()` for a member that only
# lives boxed)
union_switch(body, fc::FnCtx, v::CGVal, ty::LLVM.LLVMType; boxed=nothing) =
    tindex_switch((_, M) -> body(M), fc, union_tindex_value(fc, v), union_members(v.typ), ty;
                  default=union_has_boxed(v.typ) ? something(boxed, () -> undef_value(ty)) : nothing)

"""
    JuliaCodegen.box_union(fc, v, T=Any) -> LLVM.Value

The box of the union value `v`, known to be a `T`: its box if it has one, else a box of
the member.
"""
function box_union(fc::FnCtx, v::CGVal, @nospecialize(T)=Any)
    if union_has_boxed(v.typ) && !any(M -> M <: T, union_members(v.typ))
        return union_box_value(fc, v)    # it can only be a member that lives boxed
    end
    boxit() = union_switch(fc, v, T_tracked(); boxed=() -> union_box_value(fc, v)) do M
        M <: T || return undef_value(T_tracked())
        emit_box(fc, union_member(fc, v, M))
    end
    union_has_box(v.typ) || return boxit()
    return emit_if(() -> union_box_value(fc, v), fc, union_isboxed(fc, v), T_tracked();
                   name="box_union", otherwise=boxit)
end

# the type index (in U) of the object `obj`, whose type is a member of U
function boxed_tindex(fc::FnCtx, obj::LLVM.Value, @nospecialize U)
    b = fc.builder
    tag = emit_tag(fc, obj)
    t = i8(0)
    for (i, M) in enumerate(union_members(U))
        t = LLVM.select!(b, LLVM.icmp!(b, LLVM.API.LLVMIntEQ, tag, tag_constant(fc, M)), i8(i), t)
    end
    return t
end

# the object `obj` (of a type in U) as a value of the union U, keeping the box
function unbox_union(fc::FnCtx, obj::LLVM.Value, @nospecialize U)
    t = boxed_tindex(fc, obj, U)
    union_has_box(U) || return make_union(fc, U, LLVM.UndefValue(LLVM.ArrayType(LLVM.Int8Type(), 0)), t)
    default = union_has_boxed(U) ? () -> boxed_union(fc, U, obj).V : nothing
    # each member is read through its own layout (the largest member's size could be
    # out of bounds of the others)
    r = tindex_switch(fc, t, union_members(U), union_type(U); name="unbox_union", default) do i, M
        mv = repr_kind(M) === Ghost ? ghost(M, something(ghost_value(M))) : inline(M, emit_unbox(fc, obj, M))
        payload, roots = member_parts(fc, U, mv)
        make_union(fc, U, payload, i8(i | UNION_BOX_MARKER), roots; box=obj).V
    end
    return unboxed_union(U, r)
end

# a union value converted to another union (each member of `v` must be in U)
function convert_union(fc::FnCtx, v::CGVal, @nospecialize U)
    v.typ === U && return v
    b = fc.builder
    ty = union_type(U)
    ubox, vbox = union_has_box(U), union_has_box(v.typ)
    r = union_switch(fc, v, ty; boxed=() -> unbox_union(fc, union_box_value(fc, v), U).V) do M
        M <: U || return undef_value(ty)      # (a proven narrowing: cannot occur)
        mv = union_member(fc, v, M)
        if any(x -> x === M, union_members(U))
            payload, roots = member_parts(fc, U, mv)
            t = i8(union_tindex(U, M))
            if ubox && vbox      # (keeping the box)
                t = LLVM.or!(b, t, LLVM.and!(b, union_raw_tindex(fc, v), i8(UNION_BOX_MARKER)))
                return make_union(fc, U, payload, t, roots; box=union_box_value(fc, v)).V
            end
            return make_union(fc, U, payload, t, roots).V
        end
        # a member that only lives boxed in U
        box = vbox ? emit_if(() -> union_box_value(fc, v), fc, union_isboxed(fc, v), T_tracked();
                             otherwise=() -> emit_box(fc, mv)) : emit_box(fc, mv)
        return boxed_union(fc, U, box).V
    end
    return unboxed_union(U, r)
end

"""
    JuliaCodegen.to_union(fc, v, U) -> CGVal

The value `v` (of any representation) as a value of the unboxed union `U`.
"""
function to_union(fc::FnCtx, v::CGVal, @nospecialize U)
    v.kind === UnionVal && return convert_union(fc, v, U)
    if v.kind === Boxed
        if isconstant(v)
            c = const_value(fc, constant_value(v))
            c.kind === Boxed || return to_union(fc, c, U)
            any(x -> x === Core.Typeof(constant_value(v)), union_members(U)) ||
                return boxed_union(fc, U, v.V)
        end
        return unbox_union(fc, v.V, U)
    end
    M = v.typ
    ms = union_members(U)
    if !any(x -> x === M, ms)
        j = findfirst(x -> v.typ <: x, ms)
        if j === nothing
            # a member that only lives boxed (e.g. an abstract type)
            any(x -> v.typ <: x, Base.uniontypes(U)) || unsupported(v.typ, " is not a member of ", U)
            return boxed_union(fc, U, emit_box(fc, v))
        end
        M = ms[j]
        v = convert_repr(fc, v, M)
    end
    payload, roots = member_parts(fc, U, v)
    t = i8(union_tindex(U, M))
    if union_has_box(U) && v.kind === Inline && M !== Bool
        # the box of the value, if it has one: of a constant (native code keeps isbits
        # constants in unions boxed, JuliaLang/julia#55045), or the box it came from
        if isconstant(v)
            return make_union(fc, U, payload, i8(union_tindex(U, M) | UNION_BOX_MARKER), roots;
                              box=literal_pointer(fc, constant_value(v)))
        elseif v.vboxed !== nothing
            # (which may be null: then it has none)
            t = LLVM.select!(fc.builder, nonnull(fc, v.vboxed),
                             i8(union_tindex(U, M) | UNION_BOX_MARKER), t)
            return make_union(fc, U, payload, t, roots; box=v.vboxed)
        end
    end
    return make_union(fc, U, payload, t, roots)
end

"""
    JuliaCodegen.from_union(fc, v, T) -> CGVal

The union value `v` as a value of type `T` (a member, a sub-union, or a supertype).
"""
function from_union(fc::FnCtx, v::CGVal, @nospecialize T)
    k = repr_kind(T)
    k === UnionVal && return convert_union(fc, v, T)
    k === Boxed && return boxed(T, box_union(fc, v, T))
    if k === Inline || k === Ghost
        any(x -> x === T, union_members(v.typ)) || unsupported("narrowing ", v.typ, " to ", T)
        m = union_member(fc, v, T)
        if k === Inline && union_has_box(v.typ) && T !== Bool
            return CGVal(T, Inline, m.V, nothing, union_box_value(fc, v))   # (keeping the box)
        end
        return m
    end
    unsupported("converting the union ", v.typ, " to ", T)
end

# `isa(v, T)` of a union value (an i1), or `nothing` if it needs a subtype check
function union_isa(fc::FnCtx, v::CGVal, @nospecialize T)
    b = fc.builder
    t = union_tindex_value(fc, v)
    r = i1(false)
    for (i, M) in enumerate(union_members(v.typ))
        M <: T && (r = LLVM.or!(b, r, LLVM.icmp!(b, LLVM.API.LLVMIntEQ, t, i8(i))))
    end
    union_has_boxed(v.typ) || return r
    bms = Any[M for M in Base.uniontypes(v.typ) if !union_member_ok(M)]
    all(M -> typeintersect(M, T) === Union{}, bms) && return r
    isbox = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, t, i8(0))
    all(M -> M <: T, bms) && return LLVM.or!(b, r, isbox)
    (T isa DataType && isconcretetype(T)) || return nothing
    boxisa = emit_if(fc, isbox, LLVM.Int1Type(); name="union_isa", otherwise=i1(false)) do
        LLVM.icmp!(b, LLVM.API.LLVMIntEQ, emit_tag(fc, union_box_value(fc, v)), tag_constant(fc, T))
    end
    return LLVM.or!(b, r, boxisa)
end

# `typeof(v)` of a union value
function union_typeof(fc::FnCtx, v::CGVal)
    b = fc.builder
    t = union_tindex_value(fc, v)
    ms = union_members(v.typ)
    r = literal_pointer(fc, ms[end])
    for i in length(ms)-1:-1:1
        r = LLVM.select!(b, LLVM.icmp!(b, LLVM.API.LLVMIntEQ, t, i8(i)), literal_pointer(fc, ms[i]), r)
    end
    union_has_boxed(v.typ) || return r
    return emit_if(() -> typeof_box(fc, union_box_value(fc, v)), fc,
                   LLVM.icmp!(b, LLVM.API.LLVMIntEQ, t, i8(0)), T_tracked();
                   name="union_typeof", otherwise=r)
end
