# The JIT driver: calls compiled into Julia's JIT, cached by CodeInstance.

jd_fib(n) = n < 2 ? n : jd_fib(n - 1) + jd_fib(n - 2)
jd_greet(x) = string("hello ", x)
jd_sum(v) = (s = zero(eltype(v)); for x in v; s += x; end; s)
jd_try(x) = try x > 0 ? x : error("negative") catch; -1 end
jd_struct(x) = (Ref(x), x + 0.5)
jd_later(x) = x + 1
jd_call_later(x) = jd_later(x) * 2
@noinline jd_vararg(xs...) = sum(xs)
jd_call_vararg(x) = jd_vararg(x, x)
# (a calling convention JuliaCodegen doesn't support)
@noinline jd_stdcall(s::String) = Int(ccall(:strlen, stdcall, Csize_t, (Cstring,), s))
jd_call_stdcall(s) = jd_stdcall(s) + 1

const JD_JIT = JuliaCodegen.JIT(; config=test_config())
jd_run(f, args...) = JuliaCodegen.jit_call(JD_JIT, f, args...)

@testset "JIT driver" begin

@testset "calls" begin
    @cgtest run=jd_run jd_fib(20)
    @cgtest run=jd_run jd_greet(42)
    @cgtest run=jd_run jd_sum([1.0, 2.0, 3.0])
    @cgtest run=jd_run jd_try(3)
    @cgtest run=jd_run jd_try(-3)
    @cgtest run=jd_run jd_struct(1)
end

@testset "cache" begin
    a = JuliaCodegen.jit_compile(JD_JIT, Tuple{typeof(jd_fib), Int})
    b = JuliaCodegen.jit_compile(JD_JIT, Tuple{typeof(jd_fib), Int})
    @test a.fptr == b.fptr && a.ci === b.ci
    @test a.ci.def === JuliaCodegen.method_instance(Tuple{typeof(jd_fib), Int}, Base.get_world_counter())
    @test a.specptr != C_NULL
end

@testset "invalidation" begin
    @test jd_run(jd_call_later, 1) == 4
    old = JuliaCodegen.jit_compile(JD_JIT, Tuple{typeof(jd_call_later), Int})
    @eval jd_later(x) = x + 100
    @test jd_run(jd_call_later, 1) == 202
    @test JuliaCodegen.jit_compile(JD_JIT, Tuple{typeof(jd_call_later), Int}) !== old
end

@testset "fallbacks" begin
    fallback = JuliaCodegen.JIT(; config=JuliaCodegen.CodegenConfig(; on_unsupported=:fallback,
                                                                    on_internal_error=:error))
    @test JuliaCodegen.jit_call(fallback, jd_call_stdcall, "four") == 5
    jf = JuliaCodegen.jit_compile(fallback, Tuple{typeof(jd_call_stdcall), String})
    @test any(((mi, why),) -> mi.def.name === :jd_stdcall, jf.fallbacks)
    @test_throws JuliaCodegen.Unsupported jd_run(jd_call_stdcall, "four")
    # varargs callees are called through the runtime
    @test jd_run(jd_call_vararg, 3) == 6
end

@testset "the specsig entry" begin
    # without the pgcstack argument, a C function
    jit = JuliaCodegen.JIT(; config=JuliaCodegen.CodegenConfig(; on_unsupported=:error,
                                                              on_internal_error=:error,
                                                              gcstack_arg=false))
    jf = JuliaCodegen.jit_compile(jit, Tuple{typeof(jd_fib), Int})
    @test ccall(jf.specptr, Int, (Int,), 20) == jd_fib(20)
end

@testset "GC and threads" begin
    # the objects the code refers to stay alive
    GC.gc(true)
    @test jd_run(jd_greet, 7) == "hello 7"
    jit = JuliaCodegen.JIT(; config=test_config())
    results = Vector{Any}(undef, 8)
    Threads.@threads for i in 1:8
        results[i] = JuliaCodegen.jit_call(jit, jd_fib, 10 + i % 2)
    end
    @test results == [jd_fib(10 + i % 2) for i in 1:8]
    @test length(jit.cache) == 1
end

end
