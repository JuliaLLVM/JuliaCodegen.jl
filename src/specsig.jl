# Julia's native specialized calling convention ("specsig", `get_specsig_function` in
# src/codegen.cpp): the convention natively compiled Julia functions call each other with,
#
#   swiftcc <ret> f([ptr sret(T) %sret,] ptr swiftself %pgcstack, args...)
#
# (or, without the pgcstack argument, `gcstack_arg=false`, in the C calling convention).
# Ghost arguments are not passed; boxed values (and unboxed unions) are passed as tracked
# pointers, primitive and vector values by value (small integers `signext` or `zeroext`),
# and other inline values by a `ptr addrspace(11)` reference. Inline results larger than
# a pointer (but floating point and vector values) are returned through `sret`.
#
# Union results are returned as `{box or null, type index}`, with the data of a member
# returned unboxed in a buffer argument (and from Julia 1.14 on, its references in a
# separate roots argument).
#
# Not handled yet: inline values with references to objects, which native code passes and
# returns with their roots in separate arguments.

"How an argument is passed in the specsig convention."
@enum SpecArg SpecValue SpecBoxed SpecByRef

"""
    JuliaCodegen.SpecSig

A function signature in Julia's native specialized calling convention: how each argument
is passed (`nothing` for ghosts, which aren't), how the result is returned (`:void`,
`:value`, `:boxed`, `:sret`, or for unions, `:union`, the box or the type index and the
data in a buffer, or `:ghosts`, the type index of a union of singletons), the number of
references of a union member returned in the roots argument (`return_roots`, 0 without
one), whether the pgcstack is passed (`gcstack`, then in the Swift calling convention),
the LLVM function type and the return and parameter attributes.
"""
struct SpecSig
    argtypes::Vector{Any}
    rettype::Any
    args::Vector{Union{Nothing,SpecArg}}
    ret::Symbol
    return_roots::Int
    gcstack::Bool
    ft::LLVM.FunctionType
    retattrs::Vector{LLVM.Attribute}
    paramattrs::Vector{Vector{LLVM.Attribute}}
end

attr(name::String) = LLVM.EnumAttribute(name)
attr(name::String, n::Integer) = LLVM.EnumAttribute(name, n)

# the attributes of a reference to an inline value of type `T`
ref_attributes(@nospecialize T) =
    LLVM.Attribute[nocapture(), attr("noundef"), attr("nonnull"),
                   attr("align", Base.datatype_alignment(T)), attr("dereferenceable", sizeof(T))]

# Whether union results return members with references unboxed, their references in a
# roots argument (from Julia 1.14 on, JuliaLang/julia#55045, with the attribute that tells
# GC lowering about them)
union_returns_roots(cgm::CGModule) = cgm.config.dialect.gc_return_roots === :attribute

# The members of the union `U` that native code's union results return unboxed, in the
# order of their type indices (from 1; `for_each_uniontype_small`): the inline ones, or
# before Julia 1.14, those without references
union_return_members(cgm::CGModule, @nospecialize U) =
    union_returns_roots(cgm) ? union_members(U) :
    Any[M for M in Base.uniontypes(U) if union_member_ok(M; bits=true)]

# the size and alignment of the buffer of a union result of type `U`, the number of roots
# of its members, and whether all its members are returned unboxed (native
# `union_alloca_type`, and `get_specsig_function`'s buffer for members that are only
# references)
function union_return_layout(cgm::CGModule, @nospecialize U)
    ms = union_return_members(cgm, U)
    data = filter(M -> !is_singleton_type(M) && !allpointers(M), ms)
    nbytes = maximum(sizeof, data; init=0)
    align = min(maximum(Base.datatype_alignment, data; init=0), 16)
    nroots = maximum((npointers(M) for M in ms if !is_singleton_type(M)); init=0)
    if nbytes == 0 && nroots > 0
        nbytes = nroots * cgm.config.target.pointer_size
        align = cgm.config.target.pointer_size
    end
    return nbytes, align, nroots, length(ms) == length(Base.uniontypes(U)) && length(ms) < 128
end

# as native `deserves_sret`
deserves_sret(cgm::CGModule, @nospecialize(T), ty::LLVM.LLVMType) =
    sizeof(T) > cgm.config.target.pointer_size &&
    !(ty isa LLVM.FloatingPointType) && !(ty isa LLVM.VectorType)

is_singleton_type(@nospecialize T) = T isa DataType && isdefined(T, :instance)

is_aggregate(ty::LLVM.LLVMType) = ty isa LLVM.StructType || ty isa LLVM.ArrayType

"""
    JuliaCodegen.specsig_abi(cgm, argtypes, rettype; gcstack_arg) -> SpecSig

The signature of a function of the Julia argument types `argtypes` and return type
`rettype` in the specsig convention, as native code declares it. With `gcstack_arg`
(by default the configuration's), the pgcstack is passed as `swiftself`; without, the
function has the C calling convention. Throws `Unsupported` for signatures it doesn't
handle.
"""
function specsig_abi(cgm::CGModule, argtypes::Vector{Any}, @nospecialize(rettype);
                     gcstack_arg::Bool=cgm.config.gcstack_arg)
    ls = cgm.layouts
    params = LLVM.LLVMType[]
    paramattrs = Vector{LLVM.Attribute}[]
    retattrs = LLVM.Attribute[]
    rk = repr_kind(rettype)
    return_roots = 0
    # (a ghost that isn't a singleton object, a `Type{T}` with a unique representation, is
    # returned boxed)
    if rk === Bottom || (rk === Ghost && is_singleton_type(rettype))
        ret, rty = :void, LLVM.VoidType()
    elseif rk === Boxed || rk === Ghost
        ret, rty = :boxed, T_tracked()
        push!(retattrs, attr("nonnull"))
    elseif rk === UnionVal
        nbytes, align, nroots, allunbox = union_return_layout(cgm, rettype)
        if nbytes > 0
            # `{box or null, type index}`, the data of an unboxed member in the buffer
            # `union_bytes_return`
            ret, rty = :union, LLVM.StructType([T_tracked(), LLVM.Int8Type()])
            push!(params, T_ptr())
            push!(paramattrs, LLVM.Attribute[attr("noalias"), nocapture(), attr("noundef"),
                                              attr("nonnull"), attr("align", align),
                                              attr("dereferenceable", nbytes)])
            if nroots > 0
                # the references of an unboxed member, in the order of their offsets
                return_roots = nroots
                ps = cgm.config.target.pointer_size
                push!(params, T_ptr())
                push!(paramattrs, LLVM.Attribute[attr("noalias"), nocapture(), attr("noundef"),
                                                  LLVM.StringAttribute("julia.return_roots", string(nroots)),
                                                  attr("nonnull"), attr("align", ps),
                                                  attr("dereferenceable", nroots * ps)])
            end
        elseif allunbox
            ret, rty = :ghosts, LLVM.Int8Type()
        else
            ret, rty = :boxed, T_tracked()
            push!(retattrs, attr("nonnull"))
        end
    else
        has_references(rettype) &&
            unsupported("the specsig convention for a result of ", rettype, ", which has references")
        lt = layout(ls, rettype).llvm
        if deserves_sret(cgm, rettype, lt)
            ret, rty = :sret, LLVM.VoidType()
            push!(params, T_ptr())
            push!(paramattrs, LLVM.Attribute[attr("noalias"), LLVM.TypeAttribute("sret", lt),
                                              ref_attributes(rettype)...])
        else
            ret, rty = :value, lt
        end
    end
    if gcstack_arg
        push!(params, T_ptr())
        push!(paramattrs, LLVM.Attribute[attr("nonnull"), attr("swiftself")])
        cgm.config.dialect.gc_stack_argument && push!(paramattrs[end], LLVM.StringAttribute("gcstack"))
    end
    args = Union{Nothing,SpecArg}[]
    for T in argtypes
        k = repr_kind(T)
        if k === Ghost
            push!(args, nothing)
            continue
        elseif k === Boxed || k === UnionVal
            push!(args, SpecBoxed)
            push!(params, T_tracked())
            push!(paramattrs, LLVM.Attribute[attr("noundef"), attr("nonnull")])
            continue
        end
        has_references(T) &&
            unsupported("the specsig convention for an argument of ", T, ", which has references")
        lt = layout(ls, T).llvm
        if is_aggregate(lt)
            push!(args, SpecByRef)
            push!(params, T_derived())
            push!(paramattrs, LLVM.Attribute[attr("readonly"), ref_attributes(T)...])
        else
            push!(args, SpecValue)
            push!(params, lt)
            ext = !(lt isa LLVM.IntegerType) ? nothing :
                  T !== Bool && T <: Signed ? "signext" : "zeroext"
            push!(paramattrs, ext === nothing ? LLVM.Attribute[] : LLVM.Attribute[attr(ext)])
        end
    end
    return SpecSig(argtypes, rettype, args, ret, return_roots, gcstack_arg, LLVM.FunctionType(rty, params),
                   retattrs, paramattrs)
end

function add_attributes!(f::Union{LLVM.Function,LLVM.CallBase}, sig::SpecSig)
    params = f isa LLVM.Function ? f.parameter_attributes : f.argument_attributes
    foreach(a -> push!(f.return_attributes, a), sig.retattrs)
    for (i, as) in enumerate(sig.paramattrs), a in as
        push!(params[i], a)
    end
end

"""
    JuliaCodegen.emit_specsig_wrapper!(cgm, info, name) -> LLVM.Function

The entry of the function `info` in the specsig convention (see
[`specsig_abi`](@ref JuliaCodegen.specsig_abi)), named `name`, which natively compiled
code can call directly. A varargs method takes its arguments one by one, as native code
passes them. Throws `Unsupported` for signatures it doesn't handle, and for signatures
ending in `Vararg`, which native code calls in the jlcall convention.
"""
function emit_specsig_wrapper!(cgm::CGModule, info::FuncInfo, name::AbstractString)
    m = info.mi.def
    isva = m isa Method && m.isva
    # (a varargs method takes its arguments one by one, as native code passes them, in a
    # signature without `Vararg`; others are called in the jlcall convention)
    argtypes = isva ? signature_argtypes(info.mi) : info.argtypes
    isva && any(T -> T isa Core.TypeofVararg, argtypes) &&
        unsupported("the specsig convention for the varargs signature of ", info.mi)
    sig = specsig_abi(cgm, argtypes, info.rettype)
    f = LLVM.Function(cgm.mod, String(name), sig.ft)
    sig.gcstack && LLVM.callconv!(f, LLVM.API.LLVMSwiftCallConv)
    init_function!(f, cgm.config.target)
    add_attributes!(f, sig)
    @dispose b=LLVM.IRBuilder() begin
        top = LLVM.BasicBlock(f, "top")
        LLVM.position!(b, LLVM.at_end(top))
        fc = FnCtx(cgm, info, nothing, b, top)
        debug_function!(fc, f)
        ps = LLVM.parameters(f)
        p = 1 + (sig.ret in (:sret, :union)) + (sig.return_roots > 0)
        if sig.gcstack
            fc.pgcstack = ps[p]
            p += 1
        end
        args = CGVal[]
        for (T, k) in zip(argtypes, sig.args)
            if k === nothing
                push!(args, ghost(T, something(ghost_value(T))))
                continue
            end
            v = ps[p]
            p += 1
            cv = if k === SpecByRef
                byref_argument(fc, T, v)
            else
                CGVal(T, k === SpecBoxed ? Boxed : Inline, v, nothing, nothing)
            end
            push!(args, cv)
        end
        isva && (args = pack_varargs(fc, info.mi, args))
        r = LLVM.call!(b, LLVM.function_type(info.llvmf), info.llvmf, call_operands(fc, info, args))
        # (the entry is the function, as native code's: inlined by any pipeline)
        push!(LLVM.function_attributes(r), LLVM.EnumAttribute("alwaysinline"))
        if sig.ret === :sret
            st = LLVM.store!(b, r, ps[1])
            LLVM.alignment!(st, Base.datatype_alignment(info.rettype))
            tbaa!(fc, st, :stack)
            LLVM.ret!(b)
        elseif sig.ret === :void
            repr_kind(info.rettype) === Bottom ? LLVM.unreachable!(b) : LLVM.ret!(b)
        elseif repr_kind(info.rettype) === Ghost
            LLVM.ret!(b, emit_box(fc, ghost(info.rettype, something(ghost_value(info.rettype)))))
        elseif repr_kind(info.rettype) === UnionVal
            # (which may box the result)
            if sig.gcstack
                fc.current_task = current_task!(b, config(fc).runtime, fc.pgcstack)
            else
                emit_prologue!(fc; safepoint=false)
            end
            LLVM.ret!(b, union_return(fc, sig, unboxed_union(info.rettype, r),
                                      sig.ret === :union ? ps[1] : nothing,
                                      sig.return_roots > 0 ? ps[2] : nothing))
        else
            LLVM.ret!(b, r)
        end
    end
    push!(cgm.entries, Entry(info.mi, LLVM.name(f), :specsig))
    return f
end

"""
    JuliaCodegen.emit_specsig_call!(fc, sig, callee, args) -> CGVal

Call `callee`, a function in the specsig convention with the signature `sig`, with the
values `args` (converted to its argument types).
"""
function emit_specsig_call!(fc::FnCtx, sig::SpecSig, callee::LLVM.Value, args::Vector{CGVal})
    b = fc.builder
    ops = LLVM.Value[]
    rt = sig.rettype
    slot = roots = nothing
    if sig.ret === :sret
        slot = entry_alloca!(fc, layout(fc, rt).llvm; align=Base.datatype_alignment(rt))
        push!(ops, slot)
    elseif sig.ret === :union
        nbytes, align, _ = union_return_layout(fc.cgm, rt)
        slot = entry_alloca!(fc, LLVM.ArrayType(LLVM.Int8Type(), nbytes); align)
        push!(ops, slot)
        if sig.return_roots > 0
            roots = roots_alloca!(fc, sig.return_roots)
            push!(ops, roots)
        end
    end
    sig.gcstack && push!(ops, fc.pgcstack)
    for (a, T, k) in zip(args, sig.argtypes, sig.args)
        k === nothing && continue
        if k === SpecBoxed
            push!(ops, emit_box(fc, a))
        elseif k === SpecValue
            push!(ops, convert_repr(fc, a, T).V)
        else
            push!(ops, byref_operand(fc, convert_repr(fc, a, T), T))
        end
    end
    r = LLVM.call!(b, sig.ft, callee, ops)
    sig.gcstack && LLVM.callconv!(r, LLVM.API.LLVMSwiftCallConv)
    add_attributes!(r, sig)
    k = repr_kind(rt)
    k === Bottom && return emit_unreachable!(fc)
    k === Ghost && return ghost(rt, something(ghost_value(rt)))
    sig.ret === :boxed && return boxed(rt, r)
    sig.ret in (:union, :ghosts) && return union_result(fc, sig, r, slot, roots)
    sig.ret === :sret && return inline(rt, tbaa!(fc, LLVM.load!(b, layout(fc, rt).llvm, slot), :stack))
    return inline(rt, r)
end

# a stack slot for `n` references returned by a call, null-initialized (a GC frame slot
# for GC lowering, native `emit_static_roots`)
function roots_alloca!(fc::FnCtx, n::Int)
    b = fc.builder
    ps = config(fc).target.pointer_size
    LLVM.position!(b, top_insertion_point(fc)) do
        a = LLVM.array_alloca!(b, T_tracked(), LLVM.ConstantInt(LLVM.Int32Type(), n))
        LLVM.alignment!(a, ps)
        tbaa!(fc, LLVM.memset!(b, a, i8(0), LLVM.ConstantInt(iptr_type(fc), n * ps), ps), :gcframe)
        a
    end
end

# the union value `v` returned in the convention of `sig`, with the buffer `buf` of the
# data of `:union` and the roots argument `roots`: its box if it has one, else for a
# member returned unboxed, its type index (and data and references), else its box; a box
# with `UNION_BOX_MARKER` and the type index of its member, if returned unboxed (0 if not)
function union_return(fc::FnCtx, sig::SpecSig, v::CGVal, buf, roots)
    b = fc.builder
    U = v.typ
    sig.ret === :boxed && return emit_box(fc, v)
    ms = union_return_members(fc.cgm, U)
    # (the type indices of `v` and of the result agree when every member is returned
    # unboxed)
    sig.ret === :ghosts && return union_tindex_value(fc, v)
    rty = LLVM.return_type(sig.ft)
    pack(data, t) = LLVM.insert_value!(b, LLVM.insert_value!(b, LLVM.UndefValue(rty), data, 0), t, 1)
    unboxed() = union_switch(fc, v, rty; boxed=() -> pack(union_box_value(fc, v), i8(UNION_BOX_MARKER))) do M
        k = findfirst(m -> m === M, ms)
        k === nothing && return pack(emit_box(fc, union_member(fc, v, M)), i8(UNION_BOX_MARKER))
        if is_singleton_type(M)
        elseif npointers(M) > 0
            # (a split value: its bytes but the references, then the references)
            rs = LLVM.Value[]
            split_store!(fc, union_member(fc, v, M).V, M, allpointers(M) ? nothing : buf, rs)
            ps = config(fc).target.pointer_size
            for (i, r) in enumerate(rs)
                st = LLVM.store!(b, r, LLVM.gep!(b, LLVM.Int8Type(), roots, [iptr(fc, (i - 1) * ps)]))
                LLVM.alignment!(st, ps)
                tbaa!(fc, st, :gcframe)
            end
        else
            st = LLVM.store!(b, union_member(fc, v, M).V, buf)
            LLVM.alignment!(st, Base.datatype_alignment(M))
        end
        pack(LLVM.null(T_tracked()), i8(k))
    end
    union_has_box(U) || return unboxed()
    return emit_if(fc, union_isboxed(fc, v), rty; name="union_return", otherwise=unboxed) do
        t = union_tindex_value(fc, v)
        k = i8(0)
        for (i, M) in enumerate(union_members(U))
            j = findfirst(m -> m === M, ms)
            j === nothing && continue
            k = LLVM.select!(b, LLVM.icmp!(b, LLVM.API.LLVMIntEQ, t, i8(i)), i8(j), k)
        end
        pack(union_box_value(fc, v), LLVM.or!(b, k, i8(UNION_BOX_MARKER)))
    end
end

# the union value of the result `r` of a call in the convention of `sig`, with the buffer
# `buf` of the data of `:union` and the roots `roots` (the inverse of `union_return`)
function union_result(fc::FnCtx, sig::SpecSig, r::LLVM.Value, buf, roots)
    b = fc.builder
    U = sig.rettype
    ms = union_return_members(fc.cgm, U)
    unboxed(t) = tindex_switch(fc, t, ms, union_type(U); name="union_result") do _, M
        v = if is_singleton_type(M)
            ghost(M, something(ghost_value(M)))
        elseif npointers(M) > 0
            ps = config(fc).target.pointer_size
            rs = LLVM.Value[]
            for i in 1:npointers(M)
                ld = LLVM.load!(b, T_tracked(), LLVM.gep!(b, LLVM.Int8Type(), roots, [iptr(fc, (i - 1) * ps)]))
                LLVM.alignment!(ld, ps)
                push!(rs, tbaa!(fc, ld, :gcframe))
            end
            inline(M, split_load(fc, M, allpointers(M) ? nothing : buf, rs))
        else
            ld = LLVM.load!(b, value_type(fc, M), buf)
            LLVM.alignment!(ld, Base.datatype_alignment(M))
            inline(M, ld)
        end
        to_union(fc, v, U).V
    end
    sig.ret === :ghosts && return unboxed_union(U, unboxed(r))
    data = LLVM.extract_value!(b, r, 0)
    t = LLVM.extract_value!(b, r, 1)
    isboxed = LLVM.icmp!(b, LLVM.API.LLVMIntNE, LLVM.and!(b, t, i8(UNION_BOX_MARKER)), i8(0))
    v = emit_if(() -> unbox_union(fc, data, U).V, fc, isboxed, union_type(U);
                name="union_result", otherwise=() -> unboxed(t))
    return unboxed_union(U, v)
end
