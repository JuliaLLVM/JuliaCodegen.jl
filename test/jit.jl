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
end

const TEST_CACHE = Dict{Any,TestCompiled}()
const TEST_LOCK = ReentrantLock()

"""
    test_compile(tt; optimize=true) -> TestCompiled

Compile the call signature `tt` with JuliaCodegen into Julia's JIT. Every module passes
`verify_ir` before Julia's pipeline runs.
"""
function test_compile(@nospecialize(tt); optimize::Bool=true)
    @lock TEST_LOCK get!(TEST_CACHE, (tt, optimize)) do
        jit = test_jit()
        config = test_config()
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
        TestCompiled(fptr, roots, ir)
    end
end

"Call `f(args...)` with code compiled by JuliaCodegen."
function cgrun(@nospecialize(f), args...)
    tt = Tuple{Core.Typeof(f), map(Core.Typeof, args)...}
    c = test_compile(tt)
    argv = Any[args...]
    return GC.@preserve argv c ccall(c.fptr, Any, (Any, Ptr{Any}, UInt32), f, argv, length(argv))
end

"The unoptimized IR JuliaCodegen generates for `f(::types...)`."
test_ir(@nospecialize(f), @nospecialize(types)) =
    test_compile(Tuple{Core.Typeof(f), types...}).ir
