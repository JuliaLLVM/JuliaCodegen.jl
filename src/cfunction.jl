# `@cfunction` (`Expr(:cfunction, ...)`): a pointer to a C-callable wrapper emitted into
# the module, as native `emit_cfunction` and `gen_cfun_wrapper` emit it. The wrapper
#
# - adopts a thread the runtime doesn't know (`julia.get_pgcstack_or_new`, which Julia's
#   PTLS lowering also turns into the GC state transition);
# - receives its arguments in the target's C ABI (as `ccall` passes them, src/cabi.jl);
# - runs the function in the latest world, restoring the caller's world age on return;
# - calls it through an entry point that the runtime's `jl_get_abi_converter` resolves for
#   the current world and caches at the call site (`cfuncdata_t`): in the specsig
#   convention when JuliaCodegen can call it so, in the jlcall convention otherwise;
# - and returns the result in the C ABI.
#
# Static parameters in the signature are the method instance's (native
# `jl_instantiate_type_in_env`), and a `Ref{T}` result is a `jl_value_t*` checked against
# `T`. A `@cfunction` of a closure (`$f`, a `Base.CFunction` with a trampoline) is not
# handled yet.

is_ref_type(@nospecialize T) = T isa DataType && T.name === Ref.body.name

# T with the static parameters of the method instance being compiled substituted
function cfunction_instantiate(fc::FnCtx, @nospecialize T)
    Base.has_free_typevars(T) || return T
    mi = method_instance(fc)
    m = mi.def
    (m isa Method && m.sig isa UnionAll) || unsupported("the @cfunction type ", T)
    vals = mi.sparam_vals
    R = try
        GC.@preserve vals ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}),
                                T, m.sig, Ptr{Any}(pointer_from_objref(vals)) + sizeof(Int))
    catch err
        err isa InterruptException && rethrow()
        unsupported("the @cfunction type ", T)
    end
    Base.has_free_typevars(R) &&
        unsupported("the @cfunction type ", T, ", with static parameters not known")
    return R
end

# the declared element type of a `Ref` result, with the method's type variables rewrapped
# (`jl_rewrap_unionall(T, method.sig)`)
function cfunction_rewrap(fc::FnCtx, @nospecialize T)
    Base.has_free_typevars(T) || return T
    m = method_instance(fc).def
    (m isa Method && m.sig isa UnionAll) || unsupported("the @cfunction result type ", T)
    rewrap(@nospecialize(t), @nospecialize(u)) = if u isa UnionAll
        t = rewrap(t, u.body)
        t === u.var ? u.var.ub : UnionAll(u.var, t)
    else
        t
    end
    R = rewrap(T, m.sig)
    Base.has_free_typevars(R) && unsupported("the @cfunction result type ", T)
    return R
end

# how a `Ref{E}` argument is received: `:ref_any` (a `jl_value_t**`), `:ref_inline` (a
# pointer to the data of an immutable value) or `:ref_obj` (the object itself)
function cfunction_ref_kind(@nospecialize E)
    E === Any && return :ref_any
    if E isa DataType && isconcretetype(E) && !ismutabletype(E)
        repr_kind(E) in (Inline, Ghost) && return :ref_inline
        unsupported("the @cfunction argument type Ref{", E, "}")
    end
    return :ref_obj
end

"""
    JuliaCodegen.emit_cfunction(fc, ex, typ) -> CGVal

The `@cfunction` expression `ex`: the address of a C-callable wrapper of its function,
emitted into the module.
"""
function emit_cfunction(fc::FnCtx, ex::Expr, @nospecialize(typ))
    outT, fexpr, rt, argt, cc = ex.args
    outT === Ptr{Cvoid} || unsupported("a @cfunction of a closure (", outT, ")")
    argt isa Core.SimpleVector || unsupported("the @cfunction argument types ", argt)
    cc = cc isa QuoteNode ? cc.value : cc
    cc in (:ccall, :cdecl, :c) || unsupported("the @cfunction calling convention ", cc)
    f = operand(fc, fexpr)
    f.kind === Bottom && return f
    isconstant(f) || unsupported("a @cfunction of a function not known at compile time")
    fobj = constant_value(f)
    cgm = fc.cgm
    # the result: a `Ref{T}` is a `jl_value_t*` of type T
    if is_ref_type(rt)
        E = rt.parameters[1]
        (E === Any || E isa TypeVar && cfunction_instantiate(fc, E) === Any) &&
            unsupported("the @cfunction result type ", rt)
        rk = :boxed
        declrt = cfunction_rewrap(fc, E)
    else
        rt = cfunction_instantiate(fc, rt)
        rt isa DataType && rt <: Ref && !(rt <: Ptr) && unsupported("the @cfunction result type ", rt)
        rk = ccall_kind(rt, true)
        declrt = rt
    end
    argt = Any[cfunction_instantiate(fc, T) for T in argt]
    any(T -> T isa Core.TypeofVararg, argt) && unsupported("a @cfunction with varargs")
    sig = c_function_sig(cgm.layouts, config(fc).target, rt, rk, argt)
    # the Julia type of each argument as the function receives it
    argjt = Any[]
    for (T, k) in zip(argt, sig.kinds)
        if k === :ref
            is_ref_type(T) || unsupported("the @cfunction argument type ", T)
            cfunction_ref_kind(T.parameters[1])
            push!(argjt, T.parameters[1])
        else
            push!(argjt, T)
        end
    end
    sigt = Tuple{Core.Typeof(fobj), argjt...}
    w = emit_cfunction_wrapper!(cgm, fc.info, fobj, rt, declrt, argt, sigt, sig)
    return inline(Ptr{Cvoid}, w)
end

function emit_cfunction_wrapper!(cgm::CGModule, info::FuncInfo, @nospecialize(fobj),
                                 @nospecialize(rt), @nospecialize(declrt), argt::Vector{Any},
                                 @nospecialize(sigt), sig::CSig)
    rk = sig.rk
    sret = rk === :sret
    params = copy(sig.params)
    sret && pushfirst!(params, T_ptr())
    w = LLVM.Function(cgm.mod, unique_name(cgm, "jlcapi", fobj), LLVM.FunctionType(sig.prt, params))
    LLVM.linkage!(w, LLVM.API.LLVMInternalLinkage)
    init_function!(w, cgm.config.target)
    # the C ABI attributes native code puts on the wrapper (`function_sig_t`)
    foreach(a -> push!(w.parameter_attributes[1], a), sig.sretattrs)
    for (i, ab) in enumerate(sig.attrs), a in ab
        push!(w.parameter_attributes[sret+i], a)
    end
    foreach(a -> push!(w.return_attributes, a), sig.retattrs)
    if isempty(sig.retattrs) && rk === :scalar && sig.prt isa LLVM.IntegerType && LLVM.width(sig.prt) < 32
        # (not native: the result extended to 32 bits, as clang does it)
        push!(w.return_attributes, LLVM.EnumAttribute(rt <: Signed ? "signext" : "zeroext"))
    end
    @dispose b=LLVM.IRBuilder() begin
        top = LLVM.BasicBlock(w, "top")
        LLVM.position!(b, LLVM.at_end(top))
        wc = FnCtx(cgm, info, nothing, b, top)
        facts = cgm.config.runtime
        wc.pgcstack = call_op!(wc, "julia.get_pgcstack_or_new"; name="pgcstack")
        wc.current_task = current_task!(b, facts, wc.pgcstack)
        agefield = LLVM.inbounds_gep!(b, LLVM.Int8Type(), wc.current_task,
                                      [i32(facts.task_world_age)], "world_age")
        T_size = size_type(cgm)
        last_age = tbaa!(wc, LLVM.load!(b, T_size, agefield), :gcframe)
        ps = LLVM.parameters(w)
        args = CGVal[const_value(wc, fobj)]
        for (i, (T, k)) in enumerate(zip(argt, sig.kinds))
            push!(args, cfunction_argument(wc, ps[sret+i], T, k, sig.fargt[i]))
        end
        res = emit_cfunction_call!(wc, sigt, declrt, args, agefield)
        if res.kind === Bottom
            # (the function never returns)
            LLVM.unreachable!(b)
        else
            r = nothing
            if rk === :boxed
                r = emit_box(wc, res)
            elseif rk === :scalar
                r = c_rewrite(wc, convert_repr(wc, res, rt).V, sig.prt, rt <: Signed)
            elseif rk === :aggregate || rk === :sret
                v = ismutabletype(rt) ? boxed(rt, emit_box(wc, res)) : convert_repr(wc, res, rt)
                val = ccall_value(wc, v, rt).V
                if rk === :aggregate
                    r = c_rewrite(wc, val, sig.prt)
                else
                    st = LLVM.store!(b, val, ps[1])
                    LLVM.alignment!(st, Base.datatype_alignment(rt))
                    tbaa!(wc, st, :stack)
                end
            end
            tbaa!(wc, LLVM.store!(b, last_age, agefield), :gcframe)
            r === nothing ? LLVM.ret!(b) : LLVM.ret!(b, r)
        end
    end
    return w
end

size_type(cgm::CGModule) = LLVM.IntType(8 * cgm.config.target.pointer_size)

# an argument of the wrapper, received as `kind` (see `CSig`) in its C type `cty`
function cfunction_argument(wc::FnCtx, p::LLVM.Value, @nospecialize(T), kind::Symbol,
                            cty::LLVM.LLVMType)
    b = wc.builder
    kind === :boxed && return boxed(T, p)
    kind === :scalar && return inline(T, c_rewrite(wc, p, cty, T <: Signed))
    kind === :aggregate && return ccall_result(wc, c_rewrite(wc, p, cty), T)
    if kind === :byval
        # (no alignment assumption about memory from C)
        return ccall_result(wc, LLVM.load!(b, cty, p; align=1), T)
    end
    E = T.parameters[1]
    rk = cfunction_ref_kind(E)
    if rk === :ref_any
        return boxed(Any, LLVM.load!(b, T_tracked(), p; align=wc.cgm.config.target.pointer_size))
    elseif rk === :ref_inline
        repr_kind(E) === Ghost && return ghost(E, something(ghost_value(E)))
        return inline(E, LLVM.load!(b, value_type(wc, E), p; align=1))
    end
    return boxed(E, LLVM.addrspacecast!(b, p, T_tracked()))
end

# `f(args...)` from the wrapper `wc` in the latest world (stored to `agefield`), as a
# value of type `declrt`, through the entry point that `jl_get_abi_converter` resolves for
# the call site
function emit_cfunction_call!(wc::FnCtx, @nospecialize(sigt), @nospecialize(declrt),
                              args::Vector{CGVal}, agefield::LLVM.Value)
    cgm = wc.cgm
    b = wc.builder
    facts = cgm.config.runtime
    T_size = size_type(cgm)
    P = T_ptr()
    spec = try
        specsig_abi(cgm, Any[sigt.parameters...], declrt)
    catch err
        err isa Unsupported || rethrow()
        nothing             # (the jlcall convention)
    end
    # the call-site data (`cfuncdata_t`): the cached entry point and the world it is valid
    # in, the last code instance (and where it is kept), the entry for dynamic dispatch
    # (made by the runtime), the result and signature types, and the flags (specsig)
    null = LLVM.null(P)
    tail = LLVM.Constant[null, null, null, literal_global(cgm, declrt), literal_global(cgm, sigt),
                         LLVM.const_inttoptr(LLVM.ConstantInt(T_size, spec === nothing ? 0 : 1), P)]
    data_fields = facts.cfunction_cache === :cfuncdata ? LLVM.Constant[null, null, tail...] : tail
    data_type = LLVM.ArrayType(P, length(data_fields))
    # (the runtime's facts are the host's)
    length(data_fields) * sizeof(Ptr{Cvoid}) == facts.cfuncdata_size ||
        unsupported("a @cfunction: the call-site data of the runtime has ", facts.cfuncdata_size, " bytes")
    data = LLVM.GlobalVariable(cgm.mod, data_type, unique_name(cgm, "jlcfuncdata"))
    LLVM.initializer!(data, LLVM.ConstantArray(P, data_fields))
    LLVM.linkage!(data, LLVM.API.LLVMPrivateLinkage)
    if facts.cfunction_cache === :cfuncdata
        fptr_slot = data
        world_slot = LLVM.const_inbounds_gep(data_type, data, [LLVM.ConstantInt(LLVM.Int32Type(), 0),
                                                             LLVM.ConstantInt(LLVM.Int32Type(), 1)])
        convargs = LLVM.Value[data]
    else
        fptr_slot = LLVM.GlobalVariable(cgm.mod, P, unique_name(cgm, "jlcfuncptr"))
        LLVM.initializer!(fptr_slot, null)
        LLVM.linkage!(fptr_slot, LLVM.API.LLVMPrivateLinkage)
        world_slot = LLVM.GlobalVariable(cgm.mod, T_size, unique_name(cgm, "jlcfuncworld"))
        LLVM.initializer!(world_slot, LLVM.ConstantInt(T_size, 0))
        LLVM.linkage!(world_slot, LLVM.API.LLVMPrivateLinkage)
        convargs = LLVM.Value[fptr_slot, world_slot, data]
    end
    W = cgm.config.target.pointer_size
    acquire(ld) = (LLVM.ordering!(ld, LLVM.API.LLVMAtomicOrderingAcquire); LLVM.alignment!(ld, W); ld)
    # acquire the cached world, then the entry point, then read the world counter: if the
    # entry point was published for that world, use it
    lw = acquire(LLVM.load!(b, T_size, world_slot))
    fptr = acquire(LLVM.load!(b, P, fptr_slot))
    world = acquire(LLVM.load!(b, T_size, world_counter(cgm)))
    tbaa!(wc, LLVM.store!(b, world, agefield), :gcframe)
    from = current_block(b)
    llvmf = current_function(wc)
    lookup = LLVM.BasicBlock(llvmf, "cfunc_lookup")
    call = LLVM.BasicBlock(llvmf, "cfunc_call")
    LLVM.br!(b, LLVM.icmp!(b, LLVM.API.LLVMIntEQ, lw, world), call, lookup)
    LLVM.position!(b, LLVM.at_end(lookup))
    conv = abi_converter(cgm, length(convargs))
    newptr = LLVM.call!(b, LLVM.function_type(conv), conv, LLVM.Value[wc.current_task; convargs])
    LLVM.br!(b, call)
    LLVM.position!(b, LLVM.at_end(call))
    target = LLVM.phi!(b, P)
    append!(LLVM.incoming(target), [(fptr, from), (newptr, lookup)])
    spec === nothing || return emit_specsig_call!(wc, spec, target, args)
    ops = LLVM.Value[emit_box(wc, a) for a in args]
    r = boxed(Any, call_op!(wc, "julia.call", target, ops...))
    declrt === Union{} && return emit_unreachable!(wc)
    declrt === Any && return r
    res = emit_typeassert(wc, CGVal[r, const_value(wc, declrt)], declrt)
    res === nothing && unsupported("checking a @cfunction result of type ", declrt)
    return res
end

# the runtime's world counter (`jl_world_counter`), which changes at run time
function world_counter(cgm::CGModule)
    haskey(LLVM.globals(cgm.mod), "jl_world_counter") && return LLVM.globals(cgm.mod)["jl_world_counter"]
    return LLVM.GlobalVariable(cgm.mod, size_type(cgm), "jl_world_counter")
end

# `void *jl_get_abi_converter(jl_task_t *ct, [fptr, last_world,] void *data)`
function abi_converter(cgm::CGModule, nargs::Int)
    name = "jl_get_abi_converter"
    haskey(LLVM.functions(cgm.mod), name) && return LLVM.functions(cgm.mod)[name]
    return LLVM.Function(cgm.mod, name, LLVM.FunctionType(T_ptr(), fill(T_ptr(), 1 + nargs)))
end
