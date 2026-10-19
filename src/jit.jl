# The JIT driver: compile calls with JuliaCodegen into Julia's JIT (LLVM.jl's `JuliaOJIT`),
# with the IR of an interpreter of its own (Julia's native inference, whose CodeInstances
# keep their sources), cached by CodeInstance, so that redefining a method recompiles what
# depends on it. Linking binds the objects the code refers to to their addresses (and
# keeps them alive with the code, which is never freed).

"""
    JuliaCodegen.JITInterpreter(world)

The interpreter of the [`JIT`](@ref JuliaCodegen.JIT): Julia's native inference, with
CodeInstances of its own cache owner that keep their (uncompressed) sources.
"""
struct JITInterpreter <: CC.AbstractInterpreter
    world::UInt
    inf_cache::Any
end
# (Julia 1.15 indexes the local inference cache)
JITInterpreter(world::UInt) =
    JITInterpreter(world, isdefined(CC, :InferenceCache) ? CC.InferenceCache() : CC.InferenceResult[])
CC.InferenceParams(::JITInterpreter) = CC.InferenceParams()
CC.OptimizationParams(::JITInterpreter) = CC.OptimizationParams()
CC.get_inference_world(i::JITInterpreter) = i.world
CC.get_inference_cache(i::JITInterpreter) = i.inf_cache
CC.cache_owner(::JITInterpreter) = :JuliaCodegen
CC.may_discard_trees(::JITInterpreter) = false
CC.may_compress(::JITInterpreter) = false

"""
    JuliaCodegen.collect_codeinfos(interp, mi) -> Vector{Pair{CodeInstance,CodeInfo}}

The CodeInstances that `interp` infers for `mi` and, transitively, for what its code
`:invoke`s, with their sources: the closed set that
[`emit_into!`](@ref JuliaCodegen.emit_into!) compiles. The first one is `mi`'s.
"""
function collect_codeinfos(interp::CC.AbstractInterpreter, mi::Core.MethodInstance)
    out = Pair{Core.CodeInstance,Core.CodeInfo}[]
    seen = IdSet{Core.MethodInstance}()
    work = [mi]
    while !isempty(work)
        m = popfirst!(work)
        m in seen && continue
        push!(seen, m)
        # (varargs methods are called through the runtime, for now)
        m.def isa Method && m !== mi && m.def.isva && continue
        ci = CC.typeinf_ext_toplevel(interp, m, CC.SOURCE_MODE_ABI)
        src = ci.inferred
        if !(src isa Core.CodeInfo)
            # (inference keeps no source of functions with a constant result)
            src = CC.typeinf_code(interp, m, true)
            src isa Core.CodeInfo || unsupported("the code of ", m, ", which inference gives no source of")
        end
        push!(out, ci => src)
        for stmt in src.code
            Meta.isexpr(stmt, :invoke) || continue
            push!(work, invoke_target(stmt.args[1]))
        end
    end
    return out
end

"""
    JuliaCodegen.JITFunction

A function compiled by the [`JIT`](@ref JuliaCodegen.JIT), for the CodeInstance `ci`:
`fptr`, its entry in the jlcall convention, and `specptr`, its entry in the specsig
convention (`C_NULL` if it has none), and the functions that call native code instead
(`fallbacks`). Calling it, `jf(f, args...)`, calls the jlcall entry.
"""
struct JITFunction
    ci::Core.CodeInstance
    fptr::Ptr{Cvoid}
    specptr::Ptr{Cvoid}
    fallbacks::Vector{Pair{Core.MethodInstance,Any}}
end

function (jf::JITFunction)(@nospecialize(f), args...)
    argv = Any[args...]
    return GC.@preserve argv ccall(jf.fptr, Any, (Any, Ptr{Any}, UInt32), f, argv, length(argv))
end

"""
    JuliaCodegen.JIT(; config=CodegenConfig(), pipeline=JuliaCppPipeline(), relocatable=true)

A JIT that compiles calls with JuliaCodegen (with the configuration `config` and the pass
pipeline `pipeline`) into Julia's JIT, through LLVM.jl's `JuliaOJIT`. With `relocatable`,
every module is checked to embed no addresses before it is linked. Thread-safe.

See [`jit_compile`](@ref JuliaCodegen.jit_compile) and [`jit_call`](@ref
JuliaCodegen.jit_call).
"""
mutable struct JIT
    config::CodegenConfig
    pipeline::Pipeline
    relocatable::Bool
    ojit::Any
    lock::ReentrantLock
    cache::IdDict{Core.CodeInstance,JITFunction}
    "The objects the code refers to, kept alive with it."
    roots::Vector{Any}
end

JIT(; config::CodegenConfig=CodegenConfig(), pipeline::Pipeline=JuliaCppPipeline(),
    relocatable::Bool=true) =
    JIT(config, pipeline, relocatable, nothing, ReentrantLock(),
        IdDict{Core.CodeInstance,JITFunction}(), Any[])

# the modules added to Julia's JIT, which every `JIT` shares, for unique names
const JIT_MODULES = Threads.Atomic{Int}(0)

"""
    JuliaCodegen.jit_compile(jit, tt; world=Base.get_world_counter()) -> JITFunction

The function `jit` compiled for a call of the signature `tt` in `world`: cached by the
CodeInstance of the call, compiled (with its callees) on first use.
"""
function jit_compile(jit::JIT, @nospecialize(tt::Type); world::UInt=Base.get_world_counter())
    mi = method_instance(tt, world)
    @lock jit.lock begin
        interp = JITInterpreter(world)
        # (inferring again makes another CodeInstance; the cache has the first)
        ci = CC.get(CC.code_cache(interp), mi, nothing)
        ci === nothing && (ci = CC.typeinf_ext_toplevel(interp, mi, CC.SOURCE_MODE_ABI))
        get!(jit.cache, ci) do
            jit_add!(jit, collect_codeinfos(interp, mi), world)
        end
    end
end

"""
    JuliaCodegen.jit_call(jit, f, args...)

Call `f(args...)` with the code `jit` compiled for it.
"""
jit_call(jit::JIT, @nospecialize(f), args...) =
    jit_compile(jit, Tuple{Core.Typeof(f), map(Core.Typeof, args)...})(f, args...)

# compile the set `codeinfos` into a module of its own, whose entries are the first
# CodeInstance's, and add it to the JIT
function jit_add!(jit::JIT, codeinfos, world::UInt)
    jit.ojit === nothing && (jit.ojit = LLVM.JuliaOJIT())
    prefix = "jlcodegen_$(Threads.atomic_add!(JIT_MODULES, 1) + 1)"
    root = first(first(codeinfos))
    names = nothing
    fallbacks = Pair{Core.MethodInstance,Any}[]
    tsctx = LLVM.ThreadSafeContext()
    tsm = LLVM.ThreadSafeModule(prefix)
    err = nothing
    tsm() do mod
        try
            cgm = CGModule(mod, jit.config; world)
            compiled, out = emit_into!(cgm, codeinfos)
            append!(fallbacks, out.fallbacks)
            if jit.relocatable
                problems = check_relocatable(mod, jit.config)
                isempty(problems) || throw(InternalError(root, ErrorException(
                    "the module embeds addresses: " * join(problems, "; ")), nothing))
            end
            # the entries of the root, under names unique in the JIT; all else is internal
            fs = compiled[root]
            entries = Dict(fs.func => prefix)
            fs.specfunc === nothing || (entries[fs.specfunc] = prefix * "_specsig")
            for f in LLVM.functions(mod)
                LLVM.isdeclaration(f) && continue
                name = get(entries, LLVM.name(f), nothing)
                if name === nothing
                    LLVM.linkage!(f, LLVM.API.LLVMInternalLinkage)
                else
                    LLVM.name!(f, name)
                end
            end
            names = (prefix, fs.specfunc === nothing ? nothing : prefix * "_specsig")
            link_literals!(jit, mod, out.literals)
            run_pipeline!(jit.pipeline, mod, jit.config)
            bind_pgcstack_resolver!(mod)
        catch e
            # (LLVM.jl wraps exceptions thrown in this callback)
            err = e
        end
    end
    LLVM.dispose(tsctx)   # (the module keeps the context alive)
    err === nothing || throw(err)
    ojit = jit.ojit
    jd = LLVM.supports_jit_dylib_creation(ojit) ? LLVM.JITDylib(ojit, prefix) : ojit.external_dylib
    LLVM.add!(ojit, jd, tsm)
    fptr = pointer(LLVM.lookup(ojit, jd, names[1]))
    specptr = names[2] === nothing ? C_NULL : pointer(LLVM.lookup(ojit, jd, names[2]))
    return JITFunction(root, fptr, specptr, fallbacks)
end

# give the globals of the objects the code refers to their addresses, keeping the objects
# alive
function link_literals!(jit::JIT, mod::LLVM.Module, literals)
    iptr = LLVM.IntType(8 * sizeof(Ptr{Cvoid}))
    for (name, x) in literals
        push!(jit.roots, x)
        addr = ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x)
        gv = LLVM.globals(mod)[name]
        LLVM.initializer!(gv, LLVM.const_inttoptr(LLVM.ConstantInt(iptr, UInt(addr)), T_ptr()))
        LLVM.constant!(gv, true)
        LLVM.linkage!(gv, LLVM.API.LLVMPrivateLinkage)
    end
end

# Where TLS isn't ELF TLS (macOS, Windows), Julia's LowerPTLS calls
# `jl_get_pgcstack_resolved`, which Julia's own JIT registers as a named global. The
# dylibs LLVM.jl creates on Julia 1.14 and later don't see it, so the JIT binds it to the
# runtime's getter.
function bind_pgcstack_resolver!(mod::LLVM.Module)
    haskey(LLVM.functions(mod), "jl_get_pgcstack_resolved") || return
    f = LLVM.functions(mod)["jl_get_pgcstack_resolved"]
    LLVM.isdeclaration(f) || return
    getter, key = Ref{Ptr{Cvoid}}(), Ref{Ptr{Cvoid}}()
    ccall(:jl_pgcstack_getkey, Cvoid, (Ptr{Ptr{Cvoid}}, Ptr{Ptr{Cvoid}}), getter, key)
    iptr = LLVM.IntType(8 * sizeof(Ptr{Cvoid}))
    LLVM.replace_uses!(f, LLVM.const_inttoptr(LLVM.ConstantInt(iptr, UInt(getter[])), LLVM.value_type(f)))
    LLVM.erase!(f)
end
