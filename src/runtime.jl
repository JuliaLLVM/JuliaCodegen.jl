# Functions of Julia's runtime that generated code calls, declared as the C++ code
# generator declares them, by their exported names (`ijl_*`); the JIT, or the linker of
# an image, binds them.

"""
    JuliaCodegen.declare_runtime(mod, name) -> LLVM.Function

The declaration of the runtime function `name` (e.g. `:jl_apply_generic`) in `mod`.
"""
function declare_runtime(mod::LLVM.Module, name::Symbol)
    sym = runtime_symbol(name)
    haskey(mod.functions, sym) && return mod.functions[sym]
    if name === :jl_apply_generic
        # `jl_value_t *(jl_value_t *F, jl_value_t **args, uint32_t nargs)` (`get_func_sig`)
        ft = LLVM.FunctionType(T_tracked(), [T_tracked(), T_ptr(), LLVM.Int32Type()])
    elseif name === :jl_invoke
        # ... and the method instance (`get_func2_sig`)
        ft = LLVM.FunctionType(T_tracked(), [T_tracked(), T_ptr(), LLVM.Int32Type(), T_tracked()])
    else
        throw(ArgumentError("unknown runtime function $name"))
    end
    f = LLVM.Function(mod, sym, ft)
    # `get_func_attrs`
    push!(f.return_attributes, LLVM.EnumAttribute("nonnull"))
    for a in (LLVM.EnumAttribute("noalias"), LLVM.EnumAttribute("readonly"), nocapture(),
              LLVM.EnumAttribute("noundef"))
        push!(f.parameter_attributes[2], a)
    end
    return f
end

# the exported name of a runtime function: `ijl_` for the `jl_` functions libjulia exports
runtime_symbol(name::Symbol) = startswith(String(name), "jl_") ? "i" * String(name) : String(name)

"The address of the runtime function `name` as an LLVM value."
runtime_function(fc::FnCtx, name::Symbol) = declare_runtime(fc.cgm.mod, name)
