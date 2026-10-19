# Functions: declarations, bodies (IRCode to LLVM IR) and jlcall entry wrappers.

"""
    JuliaCodegen.init_function!(f, target)

The attributes every function defined by the code generator has, as native code gives
them (`jl_init_function`): unwind tables on 64-bit Windows (for its exception handling,
which unwinds through every frame), a 16-byte aligned stack on 32-bit Windows, frame
pointers (on every target from Julia 1.13 on, before where native code doesn't omit them,
`jl_fpo_disabled`), and inline stack probes but on Windows.
"""
function init_function!(f::LLVM.Function, target::Target)
    (; arch, os) = platform(target.triple)
    attrs = f.function_attributes
    os === :windows && arch === :i686 && push!(attrs, LLVM.EnumAttribute("alignstack", 16))
    # (`uwtable` with `UWTableKind::Default`, which LLVM encodes as 2)
    os === :windows && arch === :x86_64 && push!(attrs, LLVM.EnumAttribute("uwtable", 2))
    # (the running Julia's rule, whose IR is emitted)
    (VERSION >= v"1.13-" || os in (:linux, :windows, :freebsd, :openbsd)) &&
        push!(attrs, LLVM.StringAttribute("frame-pointer", "all"))
    os === :windows || push!(attrs, LLVM.StringAttribute("probe-stack", "inline-asm"))
    return f
end

"""
    JuliaCodegen.declare_function!(cgm, mi, argtypes, rettype) -> FuncInfo

Declare the function of `mi` in JuliaCodegen's internal convention (see
[`FuncInfo`](@ref JuliaCodegen.FuncInfo)).
"""
function declare_function!(cgm::CGModule, mi::Core.MethodInstance, argtypes::Vector{Any},
                           @nospecialize(rettype))
    params = LLVM.LLVMType[]
    for T in argtypes
        t = value_type(cgm.layouts, T)
        t === nothing || push!(params, t)
    end
    ret = something(value_type(cgm.layouts, rettype), LLVM.VoidType())
    f = mi.def isa Method ? mi.specTypes.parameters[1] : nothing
    fobj = f isa DataType && isdefined(f, :instance) ? f.instance : nothing
    llvmf = LLVM.Function(cgm.mod, unique_name(cgm, "julia", fobj), LLVM.FunctionType(ret, params))
    LLVM.linkage!(llvmf, LLVM.API.LLVMInternalLinkage)
    init_function!(llvmf, cgm.config.target)
    rettype === Union{} && push!(llvmf.function_attributes, LLVM.EnumAttribute("noreturn"))
    info = FuncInfo(mi, llvmf, argtypes, rettype)
    cgm.funcs[mi] = info
    return info
end

"The Julia argument types of the function of `mi`, from its signature."
signature_argtypes(mi::Core.MethodInstance) =
    Any[Base.unwrap_unionall(mi.specTypes).parameters...]

# the pgcstack and the current task, and the safepoint on entry
function emit_prologue!(fc::FnCtx; safepoint::Bool=true)
    b = fc.builder
    cfg = config(fc)
    fc.pgcstack = get_pgcstack!(b, fc.cgm.mod, cfg.dialect)
    fc.current_task = current_task!(b, cfg.runtime, fc.pgcstack)
    if safepoint
        ptls = current_ptls!(b, cfg, fc.cgm.tbaa, fc.current_task)
        safepoint_poll!(b, fc.cgm.mod, cfg, fc.cgm.tbaa, ptls)
    end
    return nothing
end

function bind_arguments!(fc::FnCtx)
    params = LLVM.parameters(fc.info.llvmf)
    p = 1
    for T in fc.info.argtypes
        if repr_kind(T) === Ghost
            push!(fc.args, ghost(T, something(ghost_value(T))))
        else
            push!(fc.args, CGVal(T, repr_kind(T), params[p], nothing, nothing))
            p += 1
        end
    end
end

"""
    JuliaCodegen.emit_body!(cgm, info, ir)

Emit the body of the function `info` from its `IRCode`.
"""
function emit_body!(cgm::CGModule, info::FuncInfo, ir::CC.IRCode)
    @dispose b=LLVM.IRBuilder() begin
        top = LLVM.BasicBlock(info.llvmf, "top")
        LLVM.position!(b, LLVM.at_end(top))
        fc = FnCtx(cgm, info, ir, b, top)
        emit_prologue!(fc)
        bind_arguments!(fc)
        for i in 1:length(ir.cfg.blocks)
            push!(fc.blocks, LLVM.BasicBlock(info.llvmf, "L$i"))
        end
        # each UpsilonNode feeds one PhiCNode
        for (i, stmt) in enumerate(ir.stmts.stmt)
            stmt isa Core.PhiCNode || continue
            for v in stmt.values
                fc.upsilon_to_phic[(v::Core.SSAValue).id] = i
            end
        end
        LLVM.br!(b, fc.blocks[1])
        walk_function!(fc)
        fill_phis!(fc)
    end
    return info
end

## walker hooks

begin_block!(fc::FnCtx, bi::Int) = LLVM.position!(fc.builder, LLVM.at_end(fc.blocks[bi]))

# A block is dead when no edge into it was emitted and every predecessor has been
# emitted already (an earlier block in the IR's order).
function block_reachable(fc::FnCtx, bi::Int)
    (bi == 1 || !isempty(fc.edges[bi])) && return true
    return any(p -> p >= bi, fc.ir.cfg.blocks[bi].preds)
end

isbottom(v::CGVal) = v.kind === Bottom
method_instance(fc::FnCtx) = fc.info.mi
codegen_world(fc::FnCtx) = fc.cgm.world

# record that the current LLVM block branches to IR block `target`
add_edge!(fc::FnCtx, target::Int) = push!(fc.edges[target], (fc.cur_block, current_block(fc.builder)))

function emit_goto!(fc::FnCtx, target::Int)
    add_edge!(fc, target)
    LLVM.br!(fc.builder, fc.blocks[target])
end

@noinline throw_nonbool(@nospecialize(x)) = throw(TypeError(:if, "", Bool, x))

function emit_cond_goto!(fc::FnCtx, c::CGVal, next::Int, dest::Int)
    b = fc.builder
    cond = if c.typ === Bool && c.kind === Inline
        LLVM.trunc!(b, c.V, LLVM.Int1Type())
    elseif Bool <: c.typ && c.kind in (Boxed, UnionVal)
        # a condition that may not be a Bool: the `true` and `false` singletons, and a
        # `TypeError(:if, "", Bool, x)` for anything else
        v = convert_repr(fc, c, Any)
        ist = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, v.V, literal_pointer(fc, true))
        isf = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, v.V, literal_pointer(fc, false))
        emit_guard!(fc, LLVM.or!(b, ist, isf), throw_nonbool, v)
        ist
    else
        unsupported("a condition of type ", c.typ)
    end
    add_edge!(fc, next)
    add_edge!(fc, dest)
    LLVM.br!(fc.builder, cond, fc.blocks[next], fc.blocks[dest])
end

emit_unreachable_term!(fc::FnCtx) = LLVM.unreachable!(fc.builder)

function emit_return!(fc::FnCtx, v::CGVal)
    b = fc.builder
    v.kind === Bottom && return LLVM.unreachable!(b)
    rt = fc.info.rettype
    k = repr_kind(rt)
    (k === Ghost || k === Bottom) && return LLVM.ret!(b)
    return LLVM.ret!(b, convert_repr(fc, v, rt).V)
end

function emit_phi!(fc::FnCtx, idx::Int, node::Core.PhiNode, @nospecialize(typ))
    k = repr_kind(typ)
    k === Ghost && return ghost(typ, something(ghost_value(typ)))
    k === Bottom && return bottom()
    phi = LLVM.phi!(fc.builder, value_type(fc, typ))
    push!(fc.phis, (idx, fc.cur_block, phi))
    return CGVal(typ, k, phi, nothing, nothing)
end

function convert_value(fc::FnCtx, v::CGVal, @nospecialize(typ))
    v.kind === Bottom && return v
    if v.kind in (Ghost, Inline) && !(v.typ <: typ) && typeintersect(v.typ, typ) === Union{}
        # narrowed to a type it cannot have: the code is dead (native `update_julia_type`)
        LLVM.unreachable!(fc.builder)
        LLVM.position!(fc.builder, LLVM.at_end(LLVM.BasicBlock(current_function(fc), "dead")))
        return bottom()
    end
    return convert_repr(fc, v, typ)
end

function noreturn!(fc::FnCtx, res)
    (res isa CGVal && res.kind === Bottom) && return nothing
    LLVM.unreachable!(fc.builder)
    LLVM.position!(fc.builder, LLVM.at_end(LLVM.BasicBlock(current_function(fc), "after_noreturn")))
    return nothing
end

## phis

# An undefined value of LLVM type `ty` (a phi input on an edge where the IR value is
# undefined): like native `undef_value_for_type`, tracked pointers in it are null, as GC
# lowering roots phis that hold them.
undef_value(ty::LLVM.LLVMType) = has_tracked_pointers(ty) ? LLVM.null(ty) : LLVM.UndefValue(ty)

function has_tracked_pointers(ty::LLVM.LLVMType)
    ty isa LLVM.PointerType && return AddrSpace.Tracked <= LLVM.addrspace(ty) <= AddrSpace.Loaded
    ty isa LLVM.StructType && return any(has_tracked_pointers, LLVM.elements(ty))
    (ty isa LLVM.ArrayType || ty isa LLVM.VectorType) && return has_tracked_pointers(ty.element_type)
    return false
end

function phi_input(fc::FnCtx, node::Core.PhiNode, pred::Int)
    k = findfirst(==(pred), node.edges)
    (k === nothing || !isassigned(node.values, k)) && return nothing
    return operand(fc, node.values[k])
end

# Conversions that need control flow (between unions and other representations, and
# boxing a value that may have a box) can't be placed in front of a predecessor's
# terminator: such edges get a block of their own.
needs_edge_block(v::CGVal, @nospecialize(typ)) =
    (v.kind === UnionVal && !(repr_kind(typ) === UnionVal && v.typ === typ)) ||
    (v.kind === Boxed && repr_kind(typ) === UnionVal) ||
    (v.vboxed !== nothing && !(repr_kind(typ) === v.kind && v.typ === typ))

# redirect the edge from `from` to `to` through a new block (terminated once its
# conversions are emitted)
function split_edge!(fc::FnCtx, from::LLVM.BasicBlock, to::LLVM.BasicBlock)
    term = LLVM.terminator(from)
    edge = LLVM.BasicBlock(current_function(fc), "phi_edge")
    for i in 0:Int(LLVM.API.LLVMGetNumSuccessors(term))-1
        LLVM.API.LLVMGetSuccessor(term, i) == to.ref && LLVM.API.LLVMSetSuccessor(term, i, edge)
    end
    return edge
end

# The incoming values of the phis, converted to the phi's representation at the end of
# each predecessor, or on an edge of its own.
function fill_phis!(fc::FnCtx)
    b = fc.builder
    edge_blocks = Dict{Tuple{Int,LLVM.BasicBlock},LLVM.BasicBlock}()
    for (idx, bi, phi) in fc.phis
        node = fc.ir.stmts.stmt[idx]::Core.PhiNode
        typ = CC.widenconst(fc.ir.stmts.type[idx])
        for (pred, exitbb) in unique(fc.edges[bi])
            haskey(edge_blocks, (bi, exitbb)) && continue
            v = phi_input(fc, node, pred)
            if v !== nothing && needs_edge_block(v, typ)
                edge_blocks[(bi, exitbb)] = split_edge!(fc, exitbb, fc.blocks[bi])
            end
        end
    end
    # conversions on a split edge may add blocks: track the tail of each edge, and add the
    # incoming values once all of them are emitted
    tails = copy(edge_blocks)
    pending = Tuple{LLVM.Instruction,LLVM.Value,Tuple{Int,LLVM.BasicBlock},LLVM.BasicBlock}[]
    for (idx, bi, phi) in fc.phis
        node = fc.ir.stmts.stmt[idx]::Core.PhiNode
        typ = CC.widenconst(fc.ir.stmts.type[idx])
        for (pred, exitbb) in unique(fc.edges[bi])
            key = (bi, exitbb)
            if haskey(tails, key)
                LLVM.position!(b, LLVM.at_end(tails[key]))
            else
                LLVM.position!(b, LLVM.before(LLVM.terminator(exitbb)))
            end
            v = phi_input(fc, node, pred)
            val = (v === nothing || v.kind === Bottom) ? undef_value(LLVM.value_type(phi)) :
                  convert_repr(fc, v, typ).V
            push!(pending, (phi, val, key, current_block(b)))
            haskey(tails, key) && (tails[key] = current_block(b))
        end
    end
    for (phi, val, key, bb) in pending
        push!(LLVM.incoming(phi), (val, get(tails, key, bb)))
    end
    for ((bi, _), tail) in tails
        LLVM.position!(b, LLVM.at_end(tail))
        LLVM.br!(b, fc.blocks[bi])
    end
end

## the jlcall entry

"""
    JuliaCodegen.emit_jlcall_wrapper!(cgm, info, name) -> LLVM.Function

The entry of the function `info` in the jlcall convention, `jl_value_t *name(jl_value_t
*F, jl_value_t **args, uint32_t nargs)`: it unboxes the arguments, calls the function,
and boxes the result.
"""
function emit_jlcall_wrapper!(cgm::CGModule, info::FuncInfo, name::AbstractString)
    ft = LLVM.FunctionType(T_tracked(), [T_tracked(), T_ptr(), LLVM.Int32Type()])
    f = LLVM.Function(cgm.mod, String(name), ft)
    init_function!(f, cgm.config.target)
    @dispose b=LLVM.IRBuilder() begin
        top = LLVM.BasicBlock(f, "top")
        LLVM.position!(b, LLVM.at_end(top))
        fc = FnCtx(cgm, info, nothing, b, top)
        emit_prologue!(fc; safepoint=false)
        F, argv, _ = LLVM.parameters(f)
        ops = LLVM.Value[]
        for (i, T) in enumerate(info.argtypes)
            repr_kind(T) === Ghost && continue
            p = if i == 1
                F
            else
                slot = LLVM.gep!(b, T_tracked(), argv, [LLVM.ConstantInt(LLVM.Int64Type(), i - 2)])
                tbaa!(fc, LLVM.load!(b, T_tracked(), slot; align=config(fc).target.pointer_size), :const)
            end
            push!(ops, convert_repr(fc, boxed(Any, p), T).V)
        end
        r = LLVM.call!(b, LLVM.function_type(info.llvmf), info.llvmf, ops)
        rt = info.rettype
        k = repr_kind(rt)
        if k === Bottom
            LLVM.unreachable!(b)
        else
            res = k === Ghost ? ghost(rt, something(ghost_value(rt))) : CGVal(rt, k, r, nothing, nothing)
            LLVM.ret!(b, emit_box(fc, res))
        end
    end
    return f
end

## callees

"""
    JuliaCodegen.get_function!(cgm, mi) -> FuncInfo

The function of `mi` in the module, declared on first use and queued for emission: its
body from its IR, or a stub that calls its native code (for methods that always throw,
which are error paths, and varargs methods, for now).
"""
function get_function!(cgm::CGModule, mi::Core.MethodInstance)
    info = get(cgm.funcs, mi, nothing)
    info === nothing || return info
    m = mi.def
    (m isa Method) || unsupported("a call of the top-level code ", mi)
    ir = nothing
    rt = Any
    reason = nothing
    if m.isva
        reason = "a varargs method"
    else
        try
            ir, rt = get_ir(mi, cgm.world)
        catch err
            err isa Unsupported || rethrow()
            reason = err
        end
        ir !== nothing && rt === Union{} && (reason = "a method that always throws"; ir = nothing)
    end
    info = declare_function!(cgm, mi, signature_argtypes(mi), ir === nothing ? Any : rt)
    push!(cgm.worklist, (info, ir === nothing ? reason : ir))
    return info
end

"""
    JuliaCodegen.process_worklist!(cgm; strict)

Emit the bodies of the queued functions. A function using an unsupported construct gets
a stub that calls its native code, recorded in `cgm.fallbacks`, unless the configuration
says to throw (`on_unsupported = :error`) or it is `strict` (the entry).
"""
function process_worklist!(cgm::CGModule; strict=nothing)
    while !isempty(cgm.worklist)
        info, ir = popfirst!(cgm.worklist)
        if !(ir isa CC.IRCode)
            push!(cgm.fallbacks, info.mi => ir)
            emit_stub!(cgm, info)
            continue
        end
        try
            emit_body!(cgm, info, ir)
        catch err
            (info.mi === strict || !(err isa Unsupported)) && rethrow()
            handle_failure(cgm.config, info.mi, err, catch_backtrace())
            erase_body!(info.llvmf)
            push!(cgm.fallbacks, info.mi => err)
            emit_stub!(cgm, info)
        end
    end
end

# remove a partial body: values may be used across blocks, so detach all uses first
function erase_body!(f::LLVM.Function)
    for bb in LLVM.blocks(f), inst in LLVM.instructions(bb)
        LLVM.value_type(inst) isa LLVM.VoidType ||
            LLVM.replace_uses!(inst, LLVM.UndefValue(LLVM.value_type(inst)))
    end
    for bb in collect(LLVM.blocks(f))
        LLVM.erase!(bb)
    end
end

"""
    JuliaCodegen.emit_stub!(cgm, info)

A body for the function `info` that calls the native code of its method instance
(`jl_invoke`), with the arguments boxed.
"""
function emit_stub!(cgm::CGModule, info::FuncInfo)
    @dispose b=LLVM.IRBuilder() begin
        top = LLVM.BasicBlock(info.llvmf, "top")
        LLVM.position!(b, LLVM.at_end(top))
        fc = FnCtx(cgm, info, nothing, b, top)
        emit_prologue!(fc; safepoint=false)
        bind_arguments!(fc)
        r = emit_dynamic_call(fc, fc.args[1], fc.args[2:end], info.rettype; invoke=info.mi)
        emit_return!(fc, r)
    end
end

"""
    JuliaCodegen.emit_call_info(fc, info, args) -> CGVal

Call the function `info` with the values `args` (converted to its argument types).
"""
function emit_call_info(fc::FnCtx, info::FuncInfo, args::Vector{CGVal})
    ops = LLVM.Value[]
    for (a, T) in zip(args, info.argtypes)
        v = convert_repr(fc, a, T)
        v.kind === Ghost || push!(ops, v.V)
    end
    r = LLVM.call!(fc.builder, LLVM.function_type(info.llvmf), info.llvmf, ops)
    rt = info.rettype
    k = repr_kind(rt)
    k === Bottom && return emit_unreachable!(fc)
    k === Ghost && return ghost(rt, something(ghost_value(rt)))
    return CGVal(rt, k, r, nothing, nothing)
end
