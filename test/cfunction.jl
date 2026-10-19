# `@cfunction`: C-callable wrappers, called from C (and through `ccall` of their address).

struct CF_Pair; a::Float64; b::Float64; end
struct CF_Big; a::Int; b::Int; c::Int; d::Int; end
mutable struct CF_Mut; x::Int; end

cf_add(x::Cint, y::Float64) = x + y
cf_call_add(a, b) = ccall(@cfunction(cf_add, Float64, (Cint, Float64)), Float64, (Cint, Float64), a, b)
cf_neg(x::Int8) = -x
cf_call_neg(x) = ccall(@cfunction(cf_neg, Int8, (Int8,)), Int8, (Int8,), x)
cf_swap(p::CF_Pair) = CF_Pair(p.b, p.a)
cf_call_swap(p) = ccall(@cfunction(cf_swap, CF_Pair, (CF_Pair,)), CF_Pair, (CF_Pair,), p)
cf_big(x::Int) = CF_Big(x, 2x, 3x, 4x)
cf_call_big(x) = ccall(@cfunction(cf_big, CF_Big, (Int,)), CF_Big, (Int,), x)
cf_bump(p::Ptr{Int}) = (unsafe_store!(p, unsafe_load(p) + 1); nothing)
cf_call_bump(x) = (r = Ref(x); ccall(@cfunction(cf_bump, Cvoid, (Ptr{Int},)), Cvoid, (Ref{Int},), r); r[])
cf_twice(x::Int) = 2x
cf_call_twice(x) = ccall(@cfunction(cf_twice, Int, (Ref{Int},)), Int, (Ref{Int},), x)
cf_mut(m::CF_Mut) = (m.x *= 2; nothing)
cf_call_mut(x) = (m = CF_Mut(x); ccall(@cfunction(cf_mut, Cvoid, (Ref{CF_Mut},)), Cvoid, (Ref{CF_Mut},), m); m.x)
cf_str(n::Int) = string(n)
cf_call_str(n) = ccall(@cfunction(cf_str, Ref{String}, (Int,)), Ref{String}, (Int,), n)
cf_any(x::Any) = x isa Int ? x + 1 : 0
cf_call_any(x) = ccall(@cfunction(cf_any, Int, (Any,)), Int, (Any,), x)
cf_static(x::T) where {T} = ccall(@cfunction(identity, Ref{T}, (Ref{T},)), Ref{T}, (Ref{T},), x)
# the jlcall convention: results JuliaCodegen doesn't call in the specsig convention
cf_maybe(x::Int) = x > 0 ? x : nothing
cf_call_maybe(x) = ccall(@cfunction(cf_maybe, Ref{Union{Int,Nothing}}, (Int,)), Ref{Union{Int,Nothing}}, (Int,), x)
cf_pairref(x::Int) = (x, string(x))
cf_call_pairref(x) = ccall(@cfunction(cf_pairref, Ref{Tuple{Int,String}}, (Int,)), Ref{Tuple{Int,String}}, (Int,), x)
# from C
cf_cmp(a::Ref{Int}, b::Ref{Int}) = Cint(sign(a[] - b[]))
function cf_qsort(v::Vector{Int})
    v = copy(v)
    ccall(:qsort, Cvoid, (Ptr{Int}, Csize_t, Csize_t, Ptr{Cvoid}), v, length(v), sizeof(Int),
          @cfunction(cf_cmp, Cint, (Ref{Int}, Ref{Int})))
    return v
end
cf_ptr() = @cfunction(cf_add, Float64, (Cint, Float64))
# the latest world: a method defined after the code was compiled
cf_later(x::Int) = x + 1
cf_call_later(x) = ccall(@cfunction(cf_later, Int, (Int,)), Int, (Int,), x)

@testset "cfunction" begin

@testset "calls" begin
    @cgtest cf_call_add(Cint(2), 3.5)
    @cgtest cf_call_neg(Int8(5))
    @cgtest cf_call_swap(CF_Pair(1.0, 2.0))
    @cgtest cf_call_big(3)
    @cgtest cf_call_bump(41)
    @cgtest cf_call_twice(21)
    @cgtest cf_call_mut(21)
    @cgtest cf_call_str(42)
    @cgtest cf_call_any(41)
    @cgtest cf_call_any("x")
    @cgtest cf_static(7)
    @cgtest cf_static(2.5)
    @cgtest cf_call_maybe(3)
    @cgtest cf_call_maybe(-3)
    @cgtest cf_call_pairref(5)
    @cgtest cf_qsort([5, 3, 9, 1, 7, 2])
    # the wrapper JuliaCodegen emits, not native code's
    @test cgrun(cf_ptr) != cf_ptr()
    @test ccall(cgrun(cf_ptr), Float64, (Cint, Float64), 1, 0.5) == 1.5
end

@testset "world age" begin
    @test cgrun(cf_call_later, 1) == 2
    @eval cf_later(x::Int) = x + 100
    @test cgrun(cf_call_later, 1) == 101
end

@testset "IR" begin
    ir = test_ir(cf_ptr, ())
    @test @filecheck begin
        @check_label "define internal double @jlcapi_cf_add"
        @check "call ptr @julia.get_pgcstack_or_new()"
        @check "%world_age = getelementptr inbounds i8, ptr %current_task"
        @check "load atomic i64, ptr @jl_world_counter acquire"
        @check "call ptr @jl_get_abi_converter(ptr %current_task"
        @check "call swiftcc double %"
        @check "ret double"
        ir
    end
    # the jlcall convention for results it doesn't call in the specsig convention
    @test @filecheck begin
        @check_label "define internal ptr addrspace(10) @jlcapi_cf_maybe"
        @check "@jl_get_abi_converter"
        @check "call ptr addrspace(10) (ptr, ptr addrspace(10), ...) @julia.call(ptr %"
        test_ir(cf_call_maybe, (Int,))
    end
end

@testset "unsupported" begin
    cl(x) = (f = y -> x + y; @cfunction($f, Int, (Int,)))
    @test_throws JuliaCodegen.Unsupported test_ir(cl, (Int,))
end

end
