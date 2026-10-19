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
    # `cglobal(target, T)` up to Julia 1.13: the target is an expression
    if isconstant(f) && constant_value(f) === Core.Intrinsics.cglobal && length(ex.args) >= 2
        return emit_cglobal(fc, ex.args[2], typ)
    end
    args = CGVal[operand(fc, a) for a in ex.args[2:end]]
    # a call that inference found to throw (e.g. of an intrinsic with the wrong number of
    # arguments) goes to the runtime, which throws the error; but `throw` itself, which
    # throws through `jl_throw` as native code (which GPU compilers lower)
    if typ === Union{}
        if isconstant(f) && constant_value(f) === Core.throw
            r = emit_builtin(fc, Core.throw, args, typ)
            r === nothing || return r
        end
        return emit_dynamic_call(fc, f, args, typ)
    end
    if isconstant(f) && constant_value(f) isa Core.IntrinsicFunction
        r = emit_intrinsic(fc, constant_value(f), args, typ)
        r === nothing || return r
    elseif isconstant(f) && constant_value(f) isa Core.Builtin
        r = emit_builtin(fc, constant_value(f), args, typ)
        r === nothing || return r
    end
    return emit_dynamic_call(fc, f, args, typ)
end

# the method instance of an `:invoke`'s target (a CodeInstance or a MethodInstance)
invoke_target(@nospecialize(x)) =
    x isa Core.CodeInstance ? CC.get_ci_mi(x) : x::Core.MethodInstance

emit_invoke!(fc::FnCtx, ex::Expr, @nospecialize(typ)) =
    emit_invoke_call(fc, invoke_target(ex.args[1]), CGVal[operand(fc, a) for a in ex.args[2:end]], typ)

# the call `args` (the function first) of the method instance `mi`, a value of type `typ`
function emit_invoke_call(fc::FnCtx, mi::Core.MethodInstance, args::Vector{CGVal}, @nospecialize(typ))
    # a call whose arguments may not match the signature (an invoke of a less specific
    # method with more specific arguments is fine; others are left to the runtime)
    sig = signature_argtypes(mi)
    # (a varargs method instance whose signature has a `Vararg`, e.g. of an error path, is
    # called through the runtime, with the arguments one by one; specialized ones are
    # compiled)
    if !(mi.def isa Method) || !args_match(sig, args) ||
       (!isempty(sig) && last(sig) isa Core.TypeofVararg)
        return emit_dynamic_call(fc, args[1], args[2:end], typ; invoke=mi)
    end
    info = get_function!(fc.cgm, mi)
    # (the varargs of a varargs method in the tuple its function takes)
    mi.def.isva && (args = pack_varargs(fc, mi, args))
    r = emit_call_info(fc, info, args)
    r.kind === Bottom && return r
    return convert_repr(fc, r, typ)
end
