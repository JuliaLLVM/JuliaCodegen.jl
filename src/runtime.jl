# Functions of Julia's runtime that generated code calls, declared as the C++ code
# generator declares them, by their exported names (`ijl_*`); the JIT, or the linker of
# an image, binds them.

"""
    JuliaCodegen.declare_runtime(mod, dialect, name) -> LLVM.Function

The declaration of the runtime function `name` (e.g. `:jl_apply_generic`) in `mod`, as the
dialect's code generator declares it.
"""
function declare_runtime(mod::LLVM.Module, dialect::JuliaIR.Dialect, name::Symbol)
    sym = runtime_symbol(name)
    haskey(mod.functions, sym) && return mod.functions[sym]
    T_rooted = LLVM.PointerType(AddrSpace.CalleeRooted)
    if name === :jl_apply_generic || name === :jl_invoke
        # `jl_value_t *(jl_value_t *F, jl_value_t **args, uint32_t nargs)` (`get_func_sig`),
        # and the method instance for `jl_invoke` (`get_func2_sig`)
        params = LLVM.LLVMType[T_tracked(), T_ptr(), LLVM.Int32Type()]
        name === :jl_invoke && push!(params, T_tracked())
        f = LLVM.Function(mod, sym, LLVM.FunctionType(T_tracked(), params))
        # `get_func_attrs`
        push!(f.return_attributes, LLVM.EnumAttribute("nonnull"))
        for a in (LLVM.EnumAttribute("noalias"), LLVM.EnumAttribute("readonly"), nocapture(),
                  LLVM.EnumAttribute("noundef"))
            push!(f.parameter_attributes[2], a)
        end
    elseif name === :jl_alloc_genericmemory
        f = LLVM.Function(mod, sym, LLVM.FunctionType(T_tracked(), [T_tracked(), LLVM.Int64Type()]))
    elseif name === :jl_throw
        f = LLVM.Function(mod, sym, LLVM.FunctionType(LLVM.VoidType(), [T_rooted]))
        push!(f.function_attributes, LLVM.EnumAttribute("noreturn"))
    elseif name === :jl_subtype
        f = LLVM.Function(mod, sym, LLVM.FunctionType(LLVM.Int32Type(), [T_tracked(), T_tracked()]))
    elseif name === :jl_egal__unboxed
        f = LLVM.Function(mod, sym, LLVM.FunctionType(LLVM.Int32Type(),
                                                     [T_derived(), T_derived(), LLVM.Int64Type()]))
        push!(f.function_attributes, LLVM.EnumAttribute("nounwind"))
        if dialect.minor >= v"1.14"
            push!(f.function_attributes, LLVM.EnumAttribute("willreturn"))
            f.memory_effects = LLVM.MemoryEffects(:none; argmem=:read, inaccessiblemem=:read)
        else
            f.memory_effects = LLVM.MemoryEffects(:none; argmem=:readwrite, inaccessiblemem=:readwrite)
        end
    else
        throw(ArgumentError("unknown runtime function $name"))
    end
    return f
end

"""
    JuliaCodegen.runtime_global(mod, name, type) -> LLVM.GlobalVariable

A data symbol of Julia's runtime (e.g. `:jl_small_typeof`), declared as native code does.
"""
function runtime_global(mod::LLVM.Module, name::Symbol, @nospecialize(type::LLVM.LLVMType))
    sym = String(name)
    haskey(LLVM.globals(mod), sym) && return LLVM.globals(mod)[sym]
    gv = LLVM.GlobalVariable(mod, type, sym)
    LLVM.constant!(gv, true)
    return gv
end

# the exported name of a runtime function: `ijl_` for the `jl_` functions libjulia
# exports under both names (not the internal ones, like `jl_egal__unboxed`)
const INTERNAL_RUNTIME = (:jl_egal__unboxed, :jl_alloc_genericmemory)
runtime_symbol(name::Symbol) =
    startswith(String(name), "jl_") && !(name in INTERNAL_RUNTIME) ? "i" * String(name) : String(name)

"The address of the runtime function `name` as an LLVM value."
runtime_function(fc::FnCtx, name::Symbol) = declare_runtime(fc.cgm.mod, dialect(fc), name)
