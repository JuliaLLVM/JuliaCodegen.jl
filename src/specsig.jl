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
# Not handled yet: inline values with references to objects, which native code passes and
# returns with their roots in separate arguments, and union results, which it returns as
# a union struct with the payload in a separate argument.

"How an argument is passed in the specsig convention."
@enum SpecArg SpecValue SpecBoxed SpecByRef

"""
    JuliaCodegen.SpecSig

A function signature in Julia's native specialized calling convention: how each argument
is passed (`nothing` for ghosts, which aren't), how the result is returned (`:void`,
`:value`, `:boxed` or `:sret`), whether the pgcstack is passed (`gcstack`, then in the
Swift calling convention), the LLVM function type and the return and parameter
attributes.
"""
struct SpecSig
    argtypes::Vector{Any}
    rettype::Any
    args::Vector{Union{Nothing,SpecArg}}
    ret::Symbol
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
    # (a ghost that isn't a singleton object, a `Type{T}` with a unique representation, is
    # returned boxed)
    if rk === Bottom || (rk === Ghost && is_singleton_type(rettype))
        ret, rty = :void, LLVM.VoidType()
    elseif rk === Boxed || rk === Ghost
        ret, rty = :boxed, T_tracked()
        push!(retattrs, attr("nonnull"))
    elseif rk === UnionVal
        unsupported("the specsig convention for a result of the union ", rettype)
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
    return SpecSig(argtypes, rettype, args, ret, gcstack_arg, LLVM.FunctionType(rty, params),
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
        p = sig.ret === :sret ? 2 : 1
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
    slot = nothing
    if sig.ret === :sret
        slot = entry_alloca!(fc, layout(fc, rt).llvm; align=Base.datatype_alignment(rt))
        push!(ops, slot)
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
    sig.ret === :sret && return inline(rt, tbaa!(fc, LLVM.load!(b, layout(fc, rt).llvm, slot), :stack))
    return inline(rt, r)
end
