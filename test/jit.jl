# A minimal JIT for the tests: compile a call signature with JuliaCodegen, give the
# globals of the objects the code refers to their addresses, run Julia's pipeline, and
# add the module to Julia's JIT through LLVM.jl. The drivers of the package come later.

using LLVM.Interop: JuliaPipeline

const TEST_CONFIG = Ref{Any}(nothing)
function test_config()
    if TEST_CONFIG[] === nothing
        TEST_CONFIG[] = JuliaCodegen.CodegenConfig(; on_unsupported=:error,
                                                  on_internal_error=:error)
    end
    return TEST_CONFIG[]
end

const TEST_JIT = Ref{Any}(nothing)
function test_jit()
    TEST_JIT[] === nothing && (TEST_JIT[] = LLVM.JuliaOJIT())
    return TEST_JIT[]
end

struct TestCompiled
    fptr::Ptr{Cvoid}
    roots::Vector{Any}
    ir::String
    "The functions that call native code instead, and why."
    fallbacks::Vector{Pair{Core.MethodInstance,Any}}
end

const TEST_CACHE = Dict{Any,TestCompiled}()
const TEST_LOCK = ReentrantLock()

"""
    test_compile(tt; optimize=true, config=test_config()) -> TestCompiled

Compile the call signature `tt` with JuliaCodegen into Julia's JIT. Every module passes
`verify_ir` before Julia's pipeline runs.
"""
function test_compile(@nospecialize(tt); optimize::Bool=true, config=test_config())
    @lock TEST_LOCK get!(TEST_CACHE, (tt, optimize, config.on_unsupported)) do
        jit = test_jit()
        fallbacks = Pair{Core.MethodInstance,Any}[]
        roots = Any[]
        name = "jctest_entry_$(length(TEST_CACHE) + 1)"
        ir = ""
        tsctx = LLVM.ThreadSafeContext()
        tsm = LLVM.ThreadSafeModule("jctest")
        err = nothing
        tsm() do mod
            try
                cgm = JuliaCodegen.CGModule(mod, config)
                JuliaCodegen.emit_entry!(cgm, tt; name)
                append!(fallbacks, cgm.fallbacks)
                ir = string(mod)
                iptr = LLVM.IntType(8 * sizeof(Ptr{Cvoid}))
                for (gvname, x) in JuliaCodegen.literal_objects(cgm)
                    box = Ref{Any}(x)
                    push!(roots, box)
                    addr = ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), box[])
                    gv = LLVM.globals(mod)[gvname]
                    LLVM.initializer!(gv, LLVM.const_inttoptr(LLVM.ConstantInt(iptr, UInt(addr)),
                                                              JuliaCodegen.T_ptr()))
                    LLVM.constant!(gv, true)
                    LLVM.linkage!(gv, LLVM.API.LLVMPrivateLinkage)
                end
                verify_ir(mod)
                JuliaCodegen.target_machine(config.target) do tm
                    LLVM.run!(JuliaPipeline(; opt_level=optimize ? 2 : 0), mod, tm)
                end
                bind_pgcstack_resolver!(mod)
            catch e
                # (LLVM.jl wraps exceptions thrown in this callback)
                err = e
            end
        end
        LLVM.dispose(tsctx)   # (the module keeps the context alive)
        err === nothing || throw(err)
        jd = LLVM.supports_jit_dylib_creation(jit) ? LLVM.JITDylib(jit, name) : jit.external_dylib
        LLVM.add!(jit, jd, tsm)
        fptr = pointer(LLVM.lookup(jit, jd, name))
        TestCompiled(fptr, roots, ir, fallbacks)
    end
end

# Where TLS isn't ELF TLS (macOS, Windows), LowerPTLS calls `jl_get_pgcstack_resolved`,
# which Julia's JIT registers as a named global. The dylibs LLVM.jl creates on Julia 1.14
# and later don't see it, so the test JIT binds it to the runtime's getter itself.
function bind_pgcstack_resolver!(mod::LLVM.Module)
    haskey(mod.functions, "jl_get_pgcstack_resolved") || return
    f = mod.functions["jl_get_pgcstack_resolved"]
    LLVM.isdeclaration(f) || return
    getter, key = Ref{Ptr{Cvoid}}(), Ref{Ptr{Cvoid}}()
    ccall(:jl_pgcstack_getkey, Cvoid, (Ptr{Ptr{Cvoid}}, Ptr{Ptr{Cvoid}}), getter, key)
    iptr = LLVM.IntType(8 * sizeof(Ptr{Cvoid}))
    LLVM.replace_uses!(f, LLVM.const_inttoptr(LLVM.ConstantInt(iptr, UInt(getter[])), LLVM.value_type(f)))
    LLVM.erase!(f)
end

"Call `f(args...)` with code compiled by JuliaCodegen (with the configuration `config`)."
function cgrun(@nospecialize(f), args...; config=test_config())
    tt = Tuple{Core.Typeof(f), map(Core.Typeof, args)...}
    c = test_compile(tt; config)
    argv = Any[args...]
    return GC.@preserve argv c ccall(c.fptr, Any, (Any, Ptr{Any}, UInt32), f, argv, length(argv))
end

"The unoptimized IR JuliaCodegen generates for `f(::types...)`."
test_ir(@nospecialize(f), @nospecialize(types)) =
    test_compile(Tuple{Core.Typeof(f), types...}).ir

"The functions that call native code in what JuliaCodegen generates for `f(::types...)`."
test_fallbacks(@nospecialize(f), @nospecialize(types); config=test_config()) =
    test_compile(Tuple{Core.Typeof(f), types...}; config).fallbacks

"""
    test_module_ir(f, types; triple) -> String

The (unoptimized) module that JuliaCodegen generates for `f(::types...)` for the target
`triple`, which need not be the host's: the code is not run.
"""
function test_module_ir(@nospecialize(f), @nospecialize(types); triple::AbstractString)
    config = JuliaCodegen.CodegenConfig(; target=JuliaCodegen.Target(; triple),
                                        on_unsupported=:error, on_internal_error=:error)
    @dispose ctx=LLVM.Context() mod=LLVM.Module("jctarget") begin
        cgm = JuliaCodegen.CGModule(mod, config)
        JuliaCodegen.emit_entry!(cgm, Tuple{Core.Typeof(f), types...})
        return string(mod)
    end
end
