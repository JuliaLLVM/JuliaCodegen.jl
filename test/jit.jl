# A minimal JIT for the tests: compile a call signature with JuliaCodegen, check that the
# module is relocatable, give the globals of the objects the code refers to their
# addresses, run Julia's pipeline, and add the module to Julia's JIT through LLVM.jl. Unlike
# the package's JIT driver (`JuliaCodegen.JIT`), it compiles with native inference's IR
# and lets tests choose the entry they call.

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

emit_jlcall_entry!(cgm, @nospecialize(tt), name) = JuliaCodegen.emit_entry!(cgm, tt; name)

"""
    test_compile(tt; optimize=true, config=test_config(), emit=emit_jlcall_entry!, relocatable=true) -> TestCompiled

Compile the call signature `tt` with JuliaCodegen into Julia's JIT: `emit(cgm, tt, name)`
emits the function `name` in the jlcall convention that calls it. Every module passes
`verify_ir` before Julia's pipeline runs, and is relocatable (`check_relocatable`) unless
`relocatable=false`.
"""
function test_compile(@nospecialize(tt); optimize::Bool=true, config=test_config(),
                      emit=emit_jlcall_entry!, relocatable::Bool=true)
    @lock TEST_LOCK get!(TEST_CACHE, (tt, optimize, config, emit)) do
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
                emit(cgm, tt, name)
                out = JuliaCodegen.codegen_output(cgm)
                append!(fallbacks, out.fallbacks)
                ir = string(mod)
                problems = JuliaCodegen.check_relocatable(mod, config)
                relocatable && !isempty(problems) && error("the module for $tt is not relocatable: ", join(problems, "; "))
                iptr = LLVM.IntType(8 * sizeof(Ptr{Cvoid}))
                for (gvname, x) in out.literals
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
                JuliaCodegen.run_pipeline!(JuliaCodegen.JuliaCppPipeline(; opt_level=optimize ? 2 : 0),
                                           mod, config)
                JuliaCodegen.bind_pgcstack_resolver!(mod)
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

"""
Call `f(args...)` with code compiled by JuliaCodegen (with the configuration `config`,
through the entry `emit` emits, see [`test_compile`](@ref)).
"""
function cgrun(@nospecialize(f), args...; config=test_config(), emit=emit_jlcall_entry!,
               relocatable::Bool=true)
    tt = Tuple{Core.Typeof(f), map(Core.Typeof, args)...}
    c = test_compile(tt; config, emit, relocatable)
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
