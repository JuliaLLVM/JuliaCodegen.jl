# The driver for compilers that infer code themselves (GPUCompiler.jl, Enzyme.jl): compile a
# closed set of CodeInstances, with the IR the caller's interpreter inferred, into a module
# the caller owns. This is what Julia's `jl_emit_native` does for them, and what it returns:
# the functions of each CodeInstance, and the objects the code refers to.

"""
    JuliaCodegen.CompiledFunctions

The functions emitted for a CodeInstance by [`emit_into!`](@ref JuliaCodegen.emit_into!):
`func`, its entry in the jlcall convention, and `specfunc`, its entry in the specsig
convention (see [`specsig_abi`](@ref JuliaCodegen.specsig_abi)), or `nothing` when the
signature isn't handled in it.
"""
struct CompiledFunctions
    func::String
    specfunc::Union{Nothing,String}
end

"""
    JuliaCodegen.emit_into!(mod, codeinfos; config=CodegenConfig(), world) -> (compiled, output)
    JuliaCodegen.emit_into!(cgm, codeinfos) -> (compiled, output)

Compile the CodeInstances of `codeinfos`, `(ci, src)` pairs whose source `src` (a
`CodeInfo` or `IRCode`, optimized) the caller's interpreter inferred, into the module `mod`
(or the module of `cgm`), as Julia's `jl_emit_native` does:

- the IR of every function comes from `codeinfos`, with the return type of its
  CodeInstance; `:invoke`s of the CodeInstances (or method instances) of the set call
  their functions, and any other is compiled as a call of native code (a fallback, see
  `output.fallbacks`), or throws with `on_unsupported = :error`;
- functions that always throw are compiled too (no native-code stubs for error paths);
- every CodeInstance gets an entry in the jlcall convention and, where its signature is
  handled, one in the specsig convention (with the configuration's `gcstack_arg`), named
  as native code's (`jfptr_f_N`, and `j_f_N` for the specsig entry of `julia_f_N`); the
  functions themselves have internal linkage.

Returns `compiled`, an `IdDict` from each CodeInstance to its
[`CompiledFunctions`](@ref JuliaCodegen.CompiledFunctions), and the module's
[`CodegenOutput`](@ref JuliaCodegen.CodegenOutput), whose `literals` the caller binds to
the objects' addresses (or relocates). The pass pipeline is the caller's to run.
"""
function emit_into!(mod::LLVM.Module, codeinfos; config::CodegenConfig=CodegenConfig(),
                    world::UInt=Base.get_world_counter())
    sources = codeinfo_sources(codeinfos)
    cgm = CGModule(mod, config; world, ir_source=closed_ir_source(sources), throwing_stubs=false)
    return emit_sources!(cgm, codeinfos, sources)
end

function emit_into!(cgm::CGModule, codeinfos)
    sources = codeinfo_sources(codeinfos)
    cgm.ir_source = closed_ir_source(sources)
    cgm.throwing_stubs = false
    return emit_sources!(cgm, codeinfos, sources)
end

# the IR and return type of each method instance of `codeinfos`
function codeinfo_sources(codeinfos)
    sources = IdDict{Core.MethodInstance,Tuple{CC.IRCode,Any}}()
    for (ci, src) in codeinfos
        ci isa Core.CodeInstance || throw(ArgumentError("expected a CodeInstance, got $(typeof(ci))"))
        mi = CC.get_ci_mi(ci)
        haskey(sources, mi) &&
            throw(ArgumentError("two CodeInstances of $mi; pass one per method instance"))
        ir = src isa CC.IRCode ? src :
             src isa Core.CodeInfo ? CC.inflate_ir(src, mi) :
             throw(ArgumentError("expected the CodeInfo or IRCode of $ci, got $(typeof(src))"))
        sources[mi] = (ir, ci.rettype)
    end
    return sources
end

closed_ir_source(sources) = function (mi::Core.MethodInstance, world::UInt)
    src = get(sources, mi, nothing)
    src === nothing && unsupported("a call of ", mi, ", which is not among the code instances to compile")
    return src
end

function emit_sources!(cgm::CGModule, codeinfos, sources)
    infos = Pair{Core.CodeInstance,FuncInfo}[]
    for (ci, _) in codeinfos
        info = get_function!(cgm, CC.get_ci_mi(ci))
        push!(infos, ci => info)
        # (debug information names a function by its specsig entry, as tools look it up)
        cgm.debug_linkage[info.llvmf] = "j_" * chopprefix(LLVM.name(info.llvmf), "julia_")
    end
    process_worklist!(cgm)
    compiled = IdDict{Core.CodeInstance,CompiledFunctions}()
    for (ci, info) in infos
        # named as native code's functions: the function `julia_f_N` (which other functions
        # call), its entries `j_f_N` in the specsig convention (the prefix of native code's
        # specsig wrappers) and `jfptr_f_N` in the jlcall one
        base = chopprefix(LLVM.name(info.llvmf), "julia_")
        func = emit_jlcall_wrapper!(cgm, info, "jfptr_" * base)
        push!(cgm.entries, Entry(info.mi, LLVM.name(func), :jlcall))
        specfunc = try
            LLVM.name(emit_specsig_wrapper!(cgm, info, "j_" * base))
        catch err
            err isa Unsupported || rethrow()
            nothing
        end
        compiled[ci] = CompiledFunctions(LLVM.name(func), specfunc)
    end
    return compiled, codegen_output(cgm)
end
