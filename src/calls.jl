# Calls: of intrinsics, and through the runtime (dynamic dispatch, and `jl_invoke` for
# `:invoke`s) for everything else, for now.

"""
    JuliaCodegen.emit_dynamic_call(fc, f, args, rt; invoke=nothing) -> CGVal

Call `f(args...)` through the runtime: dynamic dispatch (`jl_apply_generic`), or with
`invoke`, the method instance to call (`jl_invoke`). The result has type `rt`.
"""
function emit_dynamic_call(fc::FnCtx, f::CGVal, args::Vector{CGVal}, @nospecialize(rt);
                           invoke::Union{Nothing,Core.MethodInstance}=nothing)
    r = emit_dynamic_call_raw(fc, f, args; invoke)
    rt === Union{} && return emit_unreachable!(fc)
    return convert_repr(fc, boxed(Any, r), rt)
end

function emit_dynamic_call_raw(fc::FnCtx, f::CGVal, args::Vector{CGVal};
                               invoke::Union{Nothing,Core.MethodInstance}=nothing)
    ops = LLVM.Value[emit_box(fc, a) for a in args]
    if invoke === nothing
        return call_op!(fc, "julia.call", runtime_function(fc, :jl_apply_generic),
                        emit_box(fc, f), ops...)
    end
    return call_op!(fc, "julia.call2", runtime_function(fc, :jl_invoke),
                    literal_pointer(fc, invoke), emit_box(fc, f), ops...)
end

"""
    JuliaCodegen.emit_unreachable!(fc) -> CGVal

End the current block with `unreachable` (after a call that never returns), and continue
in a new, dead block.
"""
function emit_unreachable!(fc::FnCtx)
    LLVM.unreachable!(fc.builder)
    LLVM.position!(fc.builder, LLVM.at_end(LLVM.BasicBlock(current_function(fc), "after_noreturn")))
    return bottom()
end

"""
    JuliaCodegen.emit_guard!(fc, cond, f, args...)

If `cond` (an `i1`) is false, call the function `f(args...)`, which throws.
"""
function emit_guard!(fc::FnCtx, cond::LLVM.Value, f::Function, args::CGVal...)
    b = fc.builder
    fail = LLVM.BasicBlock(current_function(fc), "fail")
    pass = LLVM.BasicBlock(current_function(fc), "pass")
    LLVM.br!(b, cond, pass, fail)
    LLVM.position!(b, LLVM.at_end(fail))
    emit_dynamic_call_raw(fc, const_value(fc, f), CGVal[args...])
    LLVM.unreachable!(b)
    LLVM.position!(b, LLVM.at_end(pass))
    return nothing
end

# error paths, which construct the exceptions in Julia
@noinline throw_divide_error() = throw(DivideError())
@noinline throw_error_message(msg::String) = throw(ErrorException(msg))

## walker hooks

function emit_call!(fc::FnCtx, f::CGVal, ex::Expr, @nospecialize(typ))
    args = CGVal[operand(fc, a) for a in ex.args[2:end]]
    # a call that inference found to throw (e.g. of an intrinsic with the wrong number of
    # arguments) goes to the runtime, which throws the error
    typ === Union{} && return emit_dynamic_call(fc, f, args, typ)
    if isconstant(f) && constant_value(f) isa Core.IntrinsicFunction
        r = emit_intrinsic(fc, constant_value(f), args, typ)
        r === nothing || return r
    end
    return emit_dynamic_call(fc, f, args, typ)
end

# the method instance of an `:invoke`'s target (a CodeInstance or a MethodInstance)
invoke_target(@nospecialize(x)) =
    x isa Core.CodeInstance ? CC.get_ci_mi(x) : x::Core.MethodInstance

function emit_invoke!(fc::FnCtx, ex::Expr, @nospecialize(typ))
    mi = invoke_target(ex.args[1])
    f = operand(fc, ex.args[2])
    args = CGVal[operand(fc, a) for a in ex.args[3:end]]
    return emit_dynamic_call(fc, f, args, typ; invoke=mi)
end
