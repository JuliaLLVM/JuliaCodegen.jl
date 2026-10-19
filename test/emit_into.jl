# `emit_into!`: a closed set of CodeInstances, inferred by the caller's interpreter (here,
# one with an overlay method table, as GPU compilers use), compiled into the caller's module.

const CC = Base.Compiler

Base.Experimental.@MethodTable EI_MT
ei_hook(x) = x
Base.Experimental.@overlay EI_MT ei_hook(x) = x * 100
@noinline ei_inner(x) = ei_hook(x) + 1
ei_kernel(x) = ei_inner(x) * 2
ei_fib(n) = n < 2 ? n : ei_fib(n - 1) + ei_fib(n - 2)
ei_sum(v) = (s = zero(eltype(v)); for x in v; s += x; end; s)
@noinline ei_throw(x) = throw(ArgumentError("negative"))
@noinline ei_check(x) = x > 0 ? x : ei_throw(x)
ei_checked(x) = ei_check(x) + 1
ei_try(x) = try ei_check(x) catch; -1 end
ei_pair(x) = (x, x + 1.0)
ei_missing(x) = ei_inner(x)

struct EIInterp <: CC.AbstractInterpreter
    world::UInt
    inf_cache::Any
end
# (Julia 1.15 indexes the local inference cache)
EIInterp(world) = EIInterp(world, isdefined(CC, :InferenceCache) ? CC.InferenceCache() : CC.InferenceResult[])
CC.InferenceParams(::EIInterp) = CC.InferenceParams()
CC.OptimizationParams(::EIInterp) = CC.OptimizationParams()
CC.get_inference_world(i::EIInterp) = i.world
CC.get_inference_cache(i::EIInterp) = i.inf_cache
CC.cache_owner(::EIInterp) = :jctest_emit_into
CC.method_table(i::EIInterp) = CC.OverlayMethodTable(i.world, EI_MT)
CC.may_discard_trees(::EIInterp) = false
CC.may_compress(::EIInterp) = false

# the CodeInstances (with their sources) of `mi` and of what it invokes, transitively; the
# callees `exclude` names are left out
function ei_codeinfos(mi; world=Base.get_world_counter(), exclude=())
    interp = EIInterp(world)
    out = Pair{Core.CodeInstance,Core.CodeInfo}[]
    seen = IdSet{Core.MethodInstance}()
    work = [mi]
    while !isempty(work)
        m = pop!(work)
        (m in seen || m.def.name in exclude) && continue
        push!(seen, m)
        ci = CC.typeinf_ext_toplevel(interp, m, CC.SOURCE_MODE_ABI)
        push!(out, ci => ci.inferred::Core.CodeInfo)
        for st in ci.inferred.code
            Meta.isexpr(st, :invoke) || continue
            t = st.args[1]
            push!(work, t isa Core.CodeInstance ? CC.get_ci_mi(t) : t)
        end
    end
    return out
end

# the test JIT's entry `name`: the jlcall entry of the root CodeInstance (or, with
# `specsig`, its specsig entry)
function emit_through_emit_into!(cgm, @nospecialize(tt), name; specsig=false)
    mi = JuliaCodegen.method_instance(tt, cgm.world)
    pairs = ei_codeinfos(mi; world=cgm.world)
    compiled, _ = JuliaCodegen.emit_into!(cgm, pairs)
    fs = compiled[first(pairs[1])]
    entry = LLVM.functions(cgm.mod)[specsig ? fs.specfunc : fs.func]
    # (the other entries' names are the same in every module, which the test JIT may
    # put in one dylib)
    for f in LLVM.functions(cgm.mod)
        LLVM.isdeclaration(f) || f == entry || LLVM.linkage!(f, LLVM.API.LLVMInternalLinkage)
    end
    LLVM.name!(entry, name)
end
run_emit_into(f, args...) = cgrun(f, args...; emit=emit_through_emit_into!)

const EI_GPU = JuliaCodegen.CodegenConfig(; on_unsupported=:error, on_internal_error=:error,
                                          gcstack_arg=false, safepoint_on_entry=false)

function ei_module(f, types; config=test_config(), exclude=())
    @dispose ctx=LLVM.Context() mod=LLVM.Module("jcemitinto") begin
        mi = JuliaCodegen.method_instance(Tuple{Core.Typeof(f), types...}, Base.get_world_counter())
        pairs = ei_codeinfos(mi; exclude)
        compiled, out = JuliaCodegen.emit_into!(mod, pairs; config)
        verify_ir(mod)
        return (; pairs, compiled, out, ir=string(mod),
                linkage=Dict(LLVM.name(f) => LLVM.linkage(f) for f in LLVM.functions(mod)))
    end
end

@testset "emit_into!" begin

@testset "the caller's IR" begin
    # the overlay of the interpreter, not the method native inference sees
    @test run_emit_into(ei_kernel, 3) == (300 + 1) * 2
    @test ei_kernel(3) == 8
end

@testset "differential" begin
    @cgtest run=run_emit_into ei_fib(15)
    @cgtest run=run_emit_into ei_sum([1, 2, 3, 4])
    @cgtest run=run_emit_into ei_sum(Float64[])
    @cgtest run=run_emit_into ei_checked(1)
    @cgtest run=run_emit_into ei_checked(-1)
    @cgtest run=run_emit_into ei_try(-1)
    @cgtest run=run_emit_into ei_pair(2)
end

@testset "functions" begin
    r = ei_module(ei_kernel, (Int,))
    @test length(r.compiled) == length(r.pairs) == 2
    for (ci, _) in r.pairs
        fs = r.compiled[ci]
        @test r.linkage[fs.func] == LLVM.API.LLVMExternalLinkage
        @test fs.specfunc !== nothing && r.linkage[fs.specfunc] == LLVM.API.LLVMExternalLinkage
    end
    @test count(l -> l == LLVM.API.LLVMInternalLinkage, values(r.linkage)) == 2
    @test sort([e.abi for e in r.out.entries]) == [:jlcall, :jlcall, :specsig, :specsig]
    @test isempty(r.out.fallbacks)
    # error paths are compiled, not stubs that call native code
    r = ei_module(ei_checked, (Int,))
    @test any(((ci, _),) -> CC.get_ci_mi(ci).def.name === :ei_throw && ci.rettype === Union{}, r.pairs)
    @test !any(((mi, _),) -> mi.def.name === :ei_throw, r.out.fallbacks)
end

@testset "GPU-style configuration" begin
    # no pgcstack argument (the C calling convention) and no safepoint, as with Julia's
    # `CodegenParams(gcstack_arg=false, safepoint_on_entry=false)`
    params = Base.CodegenParams(; gcstack_arg=false, safepoint_on_entry=false, prefer_specsig=true)
    for (f, types) in ((ss_id, (Int,)), (ss_swap, (SS_Pair,)), (ss_dup, (Int,)), (ss_id, (String,)),
                       (ss_mix, (Int8, Bool, UInt16, Float32, SS_Pair, Nothing, String)))
        native = sprint(io -> code_llvm(io, f, types; raw=true, optimize=false, debuginfo=:none, params))
        r = ei_module(f, types; config=EI_GPU)
        spec = r.compiled[first(r.pairs[1])].specfunc
        ours = something(match(Regex("^define .*@\\Q$spec\\E\\(.*\$", "m"), r.ir)).match
        @test normalize_header(ours) == normalize_header(something(match(r"^define .*$"m, native)).match)
        @test !occursin("@julia.safepoint", r.ir)
    end
    # the specsig entry is a C function
    c = test_compile(Tuple{typeof(ei_kernel), Int}; config=EI_GPU,
                     emit=(cgm, tt, name) -> emit_through_emit_into!(cgm, tt, name; specsig=true))
    @test ccall(c.fptr, Int, (Int,), 3) == 602
end

@testset "a closed set" begin
    # a callee that is not in the set: an error, or a call of native code
    @test_throws JuliaCodegen.Unsupported ei_module(ei_missing, (Int,); exclude=(:ei_inner,))
    fallback = JuliaCodegen.CodegenConfig(; on_unsupported=:fallback, on_internal_error=:error)
    r = ei_module(ei_missing, (Int,); config=fallback, exclude=(:ei_inner,))
    @test only(r.out.fallbacks).first.def.name === :ei_inner
    @test_throws "two CodeInstances" @dispose ctx=LLVM.Context() mod=LLVM.Module("x") begin
        JuliaCodegen.emit_into!(mod, [r.pairs; r.pairs])
    end
end

end
