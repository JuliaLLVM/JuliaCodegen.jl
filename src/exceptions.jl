# Exceptions: `try`/`catch` (EnterNode, `:leave`, `:pop_exception`, `:the_exception`), the
# values that flow into a catch block (UpsilonNode/PhiCNode), scopes (`@with`), and the
# remaining statements that throw (`:throw_undef_if_not`) or assign globals.
#
# An `enter` saves the depth of the exception stack and installs a handler, then branches
# to the next block; when an exception unwinds to the handler, it is popped and the catch
# block runs. The dialect says how a handler is installed: `julia.except_enter`, which
# LowerExcHandlers lowers (Julia 1.12), or a `jl_handler_t` on the stack, `jl_enter_handler`
# and the C library's setjmp, emitted here (1.13 and later). Values from the try region
# that the catch block reads live in volatile stack slots, as registers don't survive the
# longjmp.

i32c(x) = LLVM.ConstantInt(LLVM.Int32Type(), x)

call_runtime!(fc::FnCtx, name::Symbol, args::LLVM.Value...) =
    (f = runtime_function(fc, name); LLVM.call!(fc.builder, LLVM.function_type(f), f, collect(LLVM.Value, args)))

# the address of a Julia-visible field of the current task
task_field_address(fc::FnCtx, f::Symbol) =
    LLVM.inbounds_gep!(fc.builder, LLVM.Int8Type(), fc.current_task,
                       [iptr(fc, fieldoffset(Task, Base.fieldindex(Task, f)))])

# the setjmp of the runtime, which returns twice; with a `savemask` argument but on Windows
function declare_setjmp(fc::FnCtx)
    mod = fc.cgm.mod
    name = config(fc).runtime.setjmp
    haskey(mod.functions, name) && return mod.functions[name]
    params = setjmp_savemask(config(fc).target) ? LLVM.LLVMType[T_ptr(), LLVM.Int32Type()] :
                                                  LLVM.LLVMType[T_ptr()]
    f = LLVM.Function(mod, name, LLVM.FunctionType(LLVM.Int32Type(), params))
    push!(f.function_attributes, LLVM.EnumAttribute("returns_twice"))
    return f
end

"""
    JuliaCodegen.emit_enter!(fc, idx, stmt::Core.EnterNode) -> Bool

An `enter`: the handler of a `try` (as the dialect's code generator installs it) and/or a
change of scope; it terminates the block.
"""
function emit_enter!(fc::FnCtx, idx::Int, stmt::Core.EnterNode)
    b = fc.builder
    fc.ssavals[idx] = ghost(Nothing, nothing)
    if stmt.catch_dest == 0
        # only a change of scope (`@with` without a handler)
        isdefined(stmt, :scope) || unsupported("an `enter` without a catch block or scope")
        enter_scope!(fc, idx, stmt) || return true
        emit_goto!(fc, fc.cur_block + 1)
        return true
    end
    ct = fc.current_task
    fc.excstack[idx] = call_runtime!(fc, :jl_excstack_state, ct)
    if dialect(fc).except_enter === :task_buffer
        r = call_op!(fc, "julia.except_enter", ct)
        ok = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, LLVM.extract_value!(b, r, 0), i32c(0))
        handler = LLVM.extract_value!(b, r, 1)
    else
        rt = config(fc).runtime
        handler = entry_alloca!(fc, LLVM.ArrayType(LLVM.Int8Type(), rt.handler_size); align=rt.handler_align)
        call_runtime!(fc, :jl_enter_handler, ct, handler)
        sj = declare_setjmp(fc)
        args = setjmp_savemask(config(fc).target) ? LLVM.Value[handler, i32c(0)] : LLVM.Value[handler]
        ok = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, LLVM.call!(b, LLVM.function_type(sj), sj, args), i32c(0))
    end
    tryb = LLVM.BasicBlock(current_function(fc), "try")
    catchb = LLVM.BasicBlock(current_function(fc), "catch_pop")
    LLVM.br!(b, ok, tryb, catchb)
    # normal entry: the handler becomes the task's innermost one
    LLVM.position!(b, LLVM.at_end(tryb))
    eh = LLVM.inbounds_gep!(b, LLVM.Int8Type(), ct, [iptr(fc, config(fc).runtime.task_eh)])
    LLVM.store!(b, handler, eh; align=config(fc).target.pointer_size)
    if !isdefined(stmt, :scope) || enter_scope!(fc, idx, stmt)
        emit_goto!(fc, fc.cur_block + 1)
    end
    # an exception: the handler is popped (which restores the scope), then the catch block
    LLVM.position!(b, LLVM.at_end(catchb))
    call_runtime!(fc, :jl_pop_handler, ct, i32c(1))
    emit_goto!(fc, stmt.catch_dest)
    return true
end

# The scope of a two-argument `enter` (ScopedValues): the task's scope is replaced, and the
# old one kept alive (`gc_preserve`) until the matching `leave` restores it. Returns false
# when the scope is known to throw (the code after it is dead).
function enter_scope!(fc::FnCtx, idx::Int, stmt::Core.EnterNode)
    b = fc.builder
    scope = operand(fc, stmt.scope)
    if scope.kind === Bottom
        emit_unreachable_term!(fc)
        return false
    end
    newscope = emit_box(fc, scope)
    sp = task_field_address(fc, :scope)
    W = config(fc).target.pointer_size
    old = tbaa!(fc, LLVM.load!(b, T_tracked(), sp; align=W), :gcframe)
    # (no write barrier: old tasks are in the GC's remembered set, as in native code)
    tbaa!(fc, LLVM.store!(b, newscope, sp; align=W), :gcframe)
    clear_bound_cancel_default!(fc)
    fc.scope_restore[idx] = (call_op!(fc, "llvm.julia.gc_preserve_begin", old), old)
    return true
end

# installing a scope invalidates the task's cached scoped default for cancellation (the
# field exists from Julia 1.14 on)
function clear_bound_cancel_default!(fc::FnCtx)
    Base.fieldindex(Task, :bound_cancel_default, false) == 0 && return
    tbaa!(fc, LLVM.store!(fc.builder, i8(0), task_field_address(fc, :bound_cancel_default); align=1), :gcframe)
end

# `:leave`: pop the handlers of the `enter`s still active (`nothing` tokens are dead
# ones), then restore the scope of the outermost scope-only `enter` left
function emit_leave!(fc::FnCtx, ex::Expr)
    restore = nothing
    n = 0
    for a in ex.args
        a isa Core.SSAValue || continue
        sr = get(fc.scope_restore, a.id, nothing)
        if sr !== nothing
            call_op!(fc, "llvm.julia.gc_preserve_end", sr[1])
            restore = sr[2]
        end
        if haskey(fc.excstack, a.id)
            n += 1
            restore = nothing     # (popping the handler restores the scope)
        end
    end
    n == 0 || call_runtime!(fc, :jl_pop_handler_noexcept, fc.current_task, i32c(n))
    if restore !== nothing
        tbaa!(fc, LLVM.store!(fc.builder, restore, task_field_address(fc, :scope);
                              align=config(fc).target.pointer_size), :gcframe)
        clear_bound_cancel_default!(fc)
    end
    return nothing
end

## PhiC and Upsilon

function phic_slot!(fc::FnCtx, phic::Int)
    get!(fc.phic_slots, phic) do
        typ = CC.widenconst(fc.ir.stmts.type[phic])
        ty = value_type(fc, typ)
        ty === nothing && return LLVM.null(T_ptr())     # a ghost: no slot
        slot = entry_alloca!(fc, ty)
        k = repr_kind(typ)
        if k === Boxed || k === UnionVal || (k === Inline && has_references(typ))
            # initialized, so that the GC never sees garbage in a rooted slot
            LLVM.position!(fc.builder, LLVM.after(slot)) do
                LLVM.store!(fc.builder, LLVM.null(ty), slot)
            end
        end
        slot
    end
end

function emit_upsilon!(fc::FnCtx, idx::Int, stmt::Core.UpsilonNode)
    phic = get(fc.upsilon_to_phic, idx, nothing)
    phic === nothing && return           # a dead upsilon
    isdefined(stmt, :val) || return      # an undefined value: the slot stays as it is
    typ = CC.widenconst(fc.ir.stmts.type[phic])
    repr_kind(typ) in (Ghost, Bottom) && return
    v = operand(fc, stmt.val)
    v.kind === Bottom && return
    b = fc.builder
    if !(v.typ <: typ) && repr_kind(typ) !== Boxed
        # Inference may type the PhiC more narrowly than some of its upsilons (values the
        # catch block can never observe): store a value only when it has the slot's type
        typeintersect(v.typ, typ) === Union{} && return
        cond = emit_isa(fc, v, typ)
        cond === nothing && unsupported("an upsilon of ", v.typ, " into a PhiC of type ", typ)
        st = LLVM.BasicBlock(current_function(fc), "upsilon_store")
        done = LLVM.BasicBlock(current_function(fc), "upsilon_done")
        LLVM.br!(b, cond, st, done)
        LLVM.position!(b, LLVM.at_end(st))
        tbaa!(fc, LLVM.store!(b, convert_repr(fc, v, typ).V, phic_slot!(fc, phic); volatile=true), :stack)
        LLVM.br!(b, done)
        LLVM.position!(b, LLVM.at_end(done))
        return
    end
    tbaa!(fc, LLVM.store!(b, convert_repr(fc, v, typ).V, phic_slot!(fc, phic); volatile=true), :stack)
end

function emit_phic!(fc::FnCtx, idx::Int, @nospecialize(typ))
    k = repr_kind(typ)
    k === Ghost && return ghost(typ, something(ghost_value(typ)))
    k === Bottom && return bottom()
    v = LLVM.load!(fc.builder, value_type(fc, typ), phic_slot!(fc, idx); volatile=true)
    return CGVal(typ, k, tbaa!(fc, v, :stack), nothing, nothing)
end

function emit_special_stmt!(fc::FnCtx, idx::Int, @nospecialize(stmt), @nospecialize(typ))
    if stmt isa Core.EnterNode
        return emit_enter!(fc, idx, stmt)
    elseif stmt isa Core.UpsilonNode
        emit_upsilon!(fc, idx, stmt)
    else
        fc.ssavals[idx] = emit_phic!(fc, idx, typ)
    end
    return false
end

## statements that throw, and assignments of globals

function emit_exception_head!(fc::FnCtx, idx::Int, ex::Expr, @nospecialize(typ))
    head = ex.head
    if head === :leave
        return emit_leave!(fc, ex)
    elseif head === :pop_exception
        state = get(fc.excstack, (ex.args[1]::Core.SSAValue).id, nothing)
        state === nothing && unsupported("a pop_exception of an unknown handler")
        call_runtime!(fc, :jl_restore_excstack, fc.current_task, state)
        return nothing
    elseif head === :the_exception
        return convert_repr(fc, boxed(Any, call_runtime!(fc, :jl_current_exception, fc.current_task)), typ)
    elseif head === :throw_undef_if_not
        c = operand(fc, ex.args[2])
        isconstant(c) && constant_value(c) === true && return ghost(Nothing, nothing)
        (c.typ === Bool && c.kind === Inline) || unsupported("a throw_undef_if_not of ", c.typ)
        ok = LLVM.trunc!(fc.builder, c.V, LLVM.Int1Type())
        var = ex.args[1]
        if var === :getfield_undefref || var === Symbol("##getfield##")
            emit_raise_unless!(fc, ok, UndefRefError())
        else
            # the runtime's UndefVarError of the local variable (`undef_var_error_ifnot`; a
            # Symbol, or a GlobalRef in a module context, passed to UndefVarError as is)
            b = fc.builder
            fail = LLVM.BasicBlock(current_function(fc), "err")
            pass = LLVM.BasicBlock(current_function(fc), "ok")
            LLVM.br!(b, ok, pass, fail)
            LLVM.position!(b, LLVM.at_end(fail))
            f = runtime_function(fc, :jl_undefined_var_error)
            LLVM.call!(b, LLVM.function_type(f), f,
                       LLVM.Value[callee_rooted(fc, literal_pointer(fc, var)),
                                  callee_rooted(fc, literal_pointer(fc, :local))])
            LLVM.unreachable!(b)
            LLVM.position!(b, LLVM.at_end(pass))
        end
        return ghost(Nothing, nothing)
    elseif head === :(=)
        # the assignment of a global: through its binding, or `setglobal!` with release
        # order, as native code
        lhs = ex.args[1]
        if lhs isa Core.BindingPartition
            lhs = (ccall(:jl_binding_partition_owner, Any, (Any,), lhs)::Core.Binding).globalref
        end
        lhs isa GlobalRef || unsupported("an assignment to ", typeof(lhs))
        rhs = operand(fc, ex.args[2])
        rhs.kind === Bottom && return rhs
        emit_binding_assignment!(fc, lhs, rhs) && return rhs
        emit_dynamic_call_raw(fc, const_value(fc, Core.setglobal!),
                              CGVal[const_value(fc, lhs.mod), const_value(fc, lhs.name), rhs,
                                    const_value(fc, :release)])
        return rhs
    end
    return missing
end
