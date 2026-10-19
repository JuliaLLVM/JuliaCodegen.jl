# Direct calls between functions of the module, through the JIT.

c_fib(n) = n < 2 ? n : c_fib(n - 1) + c_fib(n - 2)
c_even(n) = n == 0 ? true : c_odd(n - 1)
c_odd(n) = n == 0 ? false : c_even(n - 1)
@noinline c_add(x, y) = x + y
c_calls(x) = c_add(x, 1) + c_add(x, 2.0)
@noinline c_pair(x) = (x, string(x))
c_use_pair(x) = c_pair(x)[2]
@noinline c_maybe(x::Int) = x > 0 ? x : nothing
c_use_maybe(x) = (r = c_maybe(x); r === nothing ? -1 : r)
@noinline c_generic(x::Number) = x * 2
c_less_specific(x::Int) = invoke(c_generic, Tuple{Number}, x)
@noinline c_throws(x) = error("thrown: $x")
c_call_throws(x) = x > 0 ? x : c_throws(x)
@noinline c_vararg(xs...) = length(xs)
c_call_vararg(x) = c_vararg(x, x, x)
c_closure(x) = (y -> x + y)(3)
# (`try` is not supported yet)
@noinline c_strlen(s::String) = try parse(Int, s) catch; length(s) end
c_call_ccall(s) = c_strlen(s) + 1
function c_find(v::Vector{Int}, x::Int)
    for (i, y) in enumerate(v)
        y == x && return i
    end
    return nothing
end
function c_sum_found(v::Vector{Int})
    s = 0
    for x in v
        r = c_find(v, x)
        s += r === nothing ? 0 : r
    end
    return s
end

const C_FALLBACK = JuliaCodegen.CodegenConfig(; on_unsupported=:fallback, on_internal_error=:error)
c_run_fallback(f, args...) = cgrun(f, args...; config=C_FALLBACK)

@testset "calls" begin

@testset "direct calls" begin
    @cgtest c_fib(20)
    @cgtest c_even(11)
    @cgtest c_odd(11)
    @cgtest c_calls(3)
    @cgtest run=c_run_fallback c_use_pair(42)     # (`string` calls C)
    @cgtest c_use_maybe(3)
    @cgtest c_use_maybe(-3)
    @cgtest c_less_specific(4)
    @cgtest c_closure(4)
    @cgtest c_sum_found(collect(1:30))
end

@testset "stubs" begin
    # always throws: an error path, called through the runtime
    @cgtest c_call_throws(1)
    @cgtest c_call_throws(-1)
    @test any(((mi, why),) -> mi.def.name === :c_throws, test_fallbacks(c_call_throws, (Int,)))
    # varargs methods, for now
    @cgtest c_call_vararg(1)
    # a callee with an unsupported construct calls its native code, or throws when the
    # configuration says so
    @test c_run_fallback(c_call_ccall, "abc") == 4
    @test any(((mi, why),) -> mi.def.name === :c_strlen && why isa JuliaCodegen.Unsupported,
              test_fallbacks(c_call_ccall, (String,); config=C_FALLBACK))
    @test_throws JuliaCodegen.Unsupported cgrun(c_call_ccall, "abc")
end

@testset "code" begin
    # recursion calls the function itself, directly
    @test @filecheck begin
        @check "define internal i64 @julia_c_fib_[[N:[0-9]+]]("
        @check "call i64 @julia_c_fib_[[N]]("
        @check_not "julia.call"
        @check "define ptr addrspace(10) @jctest_entry"
        print(test_ir(c_fib, (Int,)))
    end
    # a union-returning callee is called directly, with the union by value
    @test @filecheck begin
        @check "call { [8 x i8], i8, ptr addrspace(10) } @julia_c_maybe_"
        print(test_ir(c_use_maybe, (Int,)))
    end
end

end
