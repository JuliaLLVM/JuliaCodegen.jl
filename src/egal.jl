# `===` as native code lowers it (`emit_f_is`, `emit_bits_compare`, `emit_box_compare` in
# the C++ code generator): by identity where that is equality, by contents for
# immutable values, and through the runtime's `jl_egal__unboxed` for objects compared by
# their contents. Unboxed unions are left to the runtime for now.

i1(x::Bool) = LLVM.ConstantInt(LLVM.Int1Type(), x ? 1 : 0)
iptr_type(fc::FnCtx) = LLVM.IntType(8 * config(fc).target.pointer_size)
iptr(fc::FnCtx, x::Integer) = LLVM.ConstantInt(iptr_type(fc), x)

# a Bool from an i1
bool_value(fc::FnCtx, c::LLVM.Value) = inline(Bool, LLVM.zext!(fc.builder, c, LLVM.Int8Type()))

"""
    JuliaCodegen.emit_egal(fc, x, y) -> Union{CGVal,Nothing}

`x === y`, or `nothing` if it is left to the runtime.
"""
function emit_egal(fc::FnCtx, x::CGVal, y::CGVal)
    isconstant(x) && isconstant(y) && return const_value(fc, constant_value(x) === constant_value(y))
    (x.kind === UnionVal || y.kind === UnionVal) && return nothing
    r = emit_f_is(fc, x, y)
    r isa LLVM.ConstantInt && return const_value(fc, convert(Bool, r))
    return bool_value(fc, r)
end

# the type a value is known to have (that of its constant, if it is one)
egal_type(v::CGVal) = isconstant(v) ? Core.Typeof(constant_value(v)) : v.typ

# `jl_is_kind`
iskind(@nospecialize T) = T === DataType || T === UnionAll || T === Union ||
    T === Core.TypeofBottom || (isdefined(Core, :TypeEq) && T === getfield(Core, :TypeEq)) ||
    (isdefined(Core, :TypeEgal) && T === getfield(Core, :TypeEgal))

# `jl_is_concrete_immutable`: values compared by their contents
concrete_immutable(@nospecialize T) = T isa DataType && isconcretetype(T) && !ismutabletype(T)

# `jl_pointer_egal`: whether `===` of values of type T is identity
function pointer_egal(@nospecialize T)
    T === Any && return false
    (T === Symbol || T === Bool) && return true
    U = Base.unwrap_unionall(T)
    if U isa DataType && ismutabletype(U) && T !== String && T !== Core.SimpleVector && !iskind(T)
        return true
    end
    T isa DataType && isdefined(T, :instance) && sizeof(T) == 0 && return true
    X = unique_type_parameter(T)
    if X !== nothing
        p = something(X)
        p === Union{} && return true
        p isa DataType && p !== Core.TypeofBottom && (isconcretetype(p) || isempty(p.parameters)) &&
            return true
    end
    T isa Union && return pointer_egal(T.a) && pointer_egal(T.b)
    return false
end

# Whether no other object is `===` to `x`: types are not unique objects in general
# (`Vector{T} where T` built anew is egal to `Vector`, at another address).
function pointer_unique(@nospecialize x)
    x isa Type || return true
    x === Union{} && return true
    x isa DataType || return false
    x === Core.TypeofBottom && return false
    return isconcretetype(x) || isempty(x.parameters)
end

# `func()` (an i1) if `cond`, `defval` otherwise (`emit_guarded_test`)
function emit_guarded(func, fc::FnCtx, cond::LLVM.Value, defval::Bool)
    cond isa LLVM.ConstantInt && return convert(Bool, cond) ? func() : i1(defval)
    b = fc.builder
    from = current_block(b)
    test = LLVM.BasicBlock(current_function(fc), "egal_test")
    done = LLVM.BasicBlock(current_function(fc), "egal_done")
    LLVM.br!(b, cond, test, done)
    LLVM.position!(b, LLVM.at_end(test))
    r = func()
    tend = current_block(b)
    LLVM.br!(b, done)
    LLVM.position!(b, LLVM.at_end(done))
    phi = LLVM.phi!(b, LLVM.Int1Type())
    append!(LLVM.incoming(phi), [(i1(defval), from), (r, tend)])
    return phi
end

nonnull(fc::FnCtx, p::LLVM.Value) =
    LLVM.icmp!(fc.builder, LLVM.API.LLVMIntNE, p, LLVM.null(LLVM.value_type(p)))

# values that may be undefined (null references) are egal when both are undefined
# (`emit_nullcheck_guard2`)
function emit_nullcheck_guard2(func, fc::FnCtx, null1, null2)
    null1 === nothing && null2 === nothing && return func()
    if null1 === nothing || null2 === nothing
        return emit_guarded(func, fc, nonnull(fc, something(null1, null2)), false)
    end
    n1, n2 = nonnull(fc, null1), nonnull(fc, null2)
    return emit_guarded(fc, LLVM.or!(fc.builder, n1, n2), true) do
        emit_guarded(func, fc, LLVM.and!(fc.builder, n1, n2), false)
    end
end

# whether `v` is of the concrete type `T` (`emit_exactly_isa`)
function emit_exactly_isa(fc::FnCtx, v::CGVal, @nospecialize T)
    isconstant(v) && return i1(Core.Typeof(constant_value(v)) === T)
    v.kind === Boxed &&
        return LLVM.icmp!(fc.builder, LLVM.API.LLVMIntEQ, emit_tag(fc, v.V), tag_constant(fc, T))
    return i1(v.typ === T)
end

"""
    JuliaCodegen.emit_f_is(fc, x, y; null1, null2) -> LLVM.Value

The `i1` of `x === y`. `null1`/`null2` are references whose nullness says the value is
undefined (fields of the same type, egal when both are undefined).
"""
function emit_f_is(fc::FnCtx, x::CGVal, y::CGVal; null1=nothing, null2=nothing)
    b = fc.builder
    (x.kind === Bottom || y.kind === Bottom) && return LLVM.UndefValue(LLVM.Int1Type())
    isconstant(x) && isconstant(y) && return i1(constant_value(x) === constant_value(y))
    rt1, rt2 = egal_type(x), egal_type(y)
    # disjoint concrete leaf types are never egal
    if isconcretetype(rt1) && isconcretetype(rt2) && !iskind(rt1) && !iskind(rt2) && rt1 !== rt2
        return i1(false)
    end
    # comparing with a singleton (`nothing`, `Int`, a function)
    for (a, c) in ((x, y), (y, x))
        c.kind === Ghost || continue
        cv = constant_value(c)
        if a.kind === Boxed
            pointer_unique(cv) &&
                return LLVM.icmp!(b, LLVM.API.LLVMIntEQ, a.V, literal_pointer(fc, cv))
        elseif a.kind === Ghost
            return i1(constant_value(a) === cv)
        else
            return i1(false)    # an inline value of another type than the singleton's
        end
    end
    typeintersect(rt1, rt2) === Union{} && return i1(false)
    # concrete immutable types compare by contents
    jb1 = concrete_immutable(rt1) && !iskind(rt1)
    jb2 = concrete_immutable(rt2) && !iskind(rt2)
    if jb1 || jb2
        T = jb1 ? rt1 : rt2
        k = repr_kind(T)
        if k === Inline || k === Ghost
            return emit_nullcheck_guard2(fc, null1, null2) do
                if T === Bool && (x.kind === Boxed || isconstant(x)) && (y.kind === Boxed || isconstant(y))
                    return LLVM.icmp!(b, LLVM.API.LLVMIntEQ, emit_box(fc, x), emit_box(fc, y))
                end
                rt1 === rt2 && return emit_bits_compare(fc, x, y, T)
                emit_guarded(fc, emit_exactly_isa(fc, jb1 ? y : x, T), false) do
                    emit_bits_compare(fc, x, y, T)
                end
            end
        end
    end
    return emit_box_compare(fc, x, y; null1, null2)
end

# `x === y` of values known to be of the concrete immutable type `T` (inline or ghost),
# field by field (padding is not compared)
function emit_bits_compare(fc::FnCtx, x::CGVal, y::CGVal, @nospecialize T)
    repr_kind(T) === Ghost && return i1(true)
    return bits_compare_values(fc, convert_repr(fc, x, T).V, convert_repr(fc, y, T).V, T)
end

function bits_compare_values(fc::FnCtx, x::LLVM.Value, y::LLVM.Value, @nospecialize T)
    b = fc.builder
    if isprimitivetype(T)
        ty = LLVM.value_type(x)
        if isfloat_type(ty)
            ity = LLVM.IntType(float_bits(ty))
            x, y = LLVM.bitcast!(b, x, ity), LLVM.bitcast!(b, y, ity)
        elseif ty isa LLVM.PointerType
            x, y = LLVM.ptrtoint!(b, x, iptr_type(fc)), LLVM.ptrtoint!(b, y, iptr_type(fc))
        end
        return LLVM.icmp!(b, LLVM.API.LLVMIntEQ, x, y)
    end
    lay = layout(fc, T)
    if lay.mode === VectorLayout
        # (element by element, as floats compare by their bits)
        E = fieldtype(fieldtype(T, 1), 1)
        res = i1(true)
        for i in 1:fieldcount(T)
            e = bits_compare_values(fc, extract_field(fc, lay, x, i - 1), extract_field(fc, lay, y, i - 1), E)
            res = LLVM.and!(b, res, e)
        end
        return res
    end
    res = i1(true)
    for i in 1:fieldcount(T)
        idx = lay.fieldidx[i]
        idx < 0 && continue
        FT = fieldtype(T, i)
        xi, yi = extract_field(fc, lay, x, idx), extract_field(fc, lay, y, idx)
        e = if lay.storage[i] === FieldPointer
            pointer_field_compare(fc, xi, yi, FT, maybe_undef_field(T, i))
        else
            inline_field_compare(fc, xi, yi, FT, maybe_undef_field(T, i))
        end
        res = res isa LLVM.ConstantInt && convert(Bool, res) ? e : LLVM.and!(b, res, e)
    end
    return res
end

# a reference field of declared type FT: compared as a value of that type, possibly
# undefined
function pointer_field_compare(fc::FnCtx, xi::LLVM.Value, yi::LLVM.Value, @nospecialize(FT), undef::Bool)
    n1, n2 = undef ? (xi, yi) : (nothing, nothing)
    fx, fy = boxed(FT, xi), boxed(FT, yi)
    # (references to concrete immutable values may form cycles: compared by the runtime)
    concrete_immutable(FT) && return emit_box_compare(fc, fx, fy; null1=n1, null2=n2)
    return emit_f_is(fc, fx, fy; null1=n1, null2=n2)
end

# an inline field of type FT; an undefined one has a null first reference
function inline_field_compare(fc::FnCtx, xi::LLVM.Value, yi::LLVM.Value, @nospecialize(FT), undef::Bool)
    if undef && has_references(FT)
        n1 = first(reference_values(fc, xi, FT))
        n2 = first(reference_values(fc, yi, FT))
        return emit_nullcheck_guard2(() -> bits_compare_values(fc, xi, yi, FT), fc, n1, n2)
    end
    return bits_compare_values(fc, xi, yi, FT)
end

# `jl_egal__unboxed(a, b, tag)` of two objects with the same tag
function emit_egal_unboxed(fc::FnCtx, x::LLVM.Value, y::LLVM.Value, tag::LLVM.Value)
    f = runtime_function(fc, :jl_egal__unboxed)
    b = fc.builder
    tag = LLVM.value_type(tag) == LLVM.Int64Type() ? tag : LLVM.zext!(b, tag, LLVM.Int64Type())
    r = LLVM.call!(b, LLVM.function_type(f), f, LLVM.Value[derived(fc, x), derived(fc, y), tag])
    return LLVM.trunc!(b, r, LLVM.Int1Type())
end

# identical objects, or objects of the same type with egal contents (`emit_box_compare`)
function emit_box_compare(fc::FnCtx, x::CGVal, y::CGVal; null1=nothing, null2=nothing)
    b = fc.builder
    if pointer_egal(x.typ) || pointer_egal(y.typ)
        return emit_nullcheck_guard2(fc, nothing, nothing) do
            LLVM.icmp!(b, LLVM.API.LLVMIntEQ, emit_box(fc, x), emit_box(fc, y))
        end
    end
    return emit_nullcheck_guard2(fc, null1, null2) do
        px, py = emit_box(fc, x), emit_box(fc, y)
        neq = LLVM.icmp!(b, LLVM.API.LLVMIntNE, px, py)
        emit_guarded(fc, neq, true) do
            tx = emit_tag(fc, px)
            same = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, tx, emit_tag(fc, py))
            emit_guarded(() -> emit_egal_unboxed(fc, px, py, tx), fc, same, false)
        end
    end
end
