# Unboxed unions, through the JIT.

struct UPair; a::Int; b::Float64; end
struct UWithRef; n::Int; s::String; end
mutable struct UHolder; x::Union{Nothing,Int}; y::Union{Int8,Float32,Nothing}; end

u_maybe(c::Bool, x) = c ? x : nothing
u_three(i::Int) = i == 1 ? 1 : i == 2 ? 2.5 : i == 3 ? "three" : nothing
u_pick(i::Int) = i == 1 ? UPair(1, 2.0) : i == 2 ? UWithRef(3, "x") : nothing
u_something(x) = x === nothing ? 0 : x
u_widen(c::Bool, x::Int) = (r = u_maybe(c, x); r === nothing ? missing : r)
u_isa(x) = (x isa Int, x isa Nothing, x isa Real, x isa String)
u_typeof(x) = typeof(x)
u_egal(x, y) = x === y
u_box(x) = Any[x][1]
u_get(h::UHolder) = (h.x, h.y)
u_set!(h::UHolder, x, y) = (h.x = x; h.y = y; h)
u_new(x, y) = UHolder(x, y)
u_cond(x) = x ? 1 : 2          # a condition that may not be a Bool
function u_phi(c::Bool, d::Bool, x::Int)
    r = c ? x : nothing
    d && return 0
    return r
end
function u_find(v::Vector{Int}, x::Int)
    for (i, y) in enumerate(v)
        y == x && return i
    end
    return nothing
end
function u_sum_found(v::Vector{Int})
    s = 0
    for x in v
        r = u_find(v, x)
        s += r === nothing ? 0 : r
    end
    return s
end

@noinline u_produce(c::Bool, a::Int32) = c ? a : 2.5
u_box_const(c::Bool) = Any[u_produce(c, Int32(7))][1]

@testset "unions" begin

@testset "members" begin
    for c in (true, false)
        @cgtest u_maybe(c, 1)
        @cgtest u_maybe(c, 1.5)
        @cgtest u_maybe(c, UPair(1, 2.0))
        @cgtest u_maybe(c, UWithRef(1, "a"))
        @cgtest u_maybe(c, "s")
        @cgtest u_widen(c, 3)
    end
    for i in 1:4
        @cgtest u_three(i)
        @cgtest u_pick(i)
        @cgtest u_isa(u_three(i))
        @cgtest u_typeof(u_three(i))
    end
    @cgtest u_something(nothing)
    @cgtest u_something(4)
end

@testset "union arguments" begin
    for x in Any[1, nothing, 2.5, "s"]
        @cgtest u_isa(x)
        @cgtest u_box(x)
    end
    f(x::Union{Int,Nothing}) = u_isa(x)
    g(x::Union{Int,Nothing}, y::Union{Int,Nothing}) = x === y
    for x in (1, nothing), y in (1, 2, nothing)
        @cgtest f(x)
        @cgtest g(x, y)
    end
end

@testset "union fields" begin
    @cgtest u_get(UHolder(1, Int8(2)))
    @cgtest u_get(UHolder(nothing, 1.5f0))
    @cgtest u_get(UHolder(nothing, nothing))
    @cgtest u_set!(UHolder(1, nothing), nothing, Int8(3))
    @cgtest u_set!(UHolder(nothing, nothing), 5, 2.5f0)
    @cgtest u_new(1, Int8(1))
    @cgtest u_new(nothing, nothing)
end

@testset "conditions" begin
    @cgtest u_cond(true)
    @cgtest u_cond(false)
    @cgtest u_cond(1)                     # TypeError
end

@testset "code" begin
    @cgtest u_find([1, 2, 3], 2)
    @cgtest u_find([1, 2, 3], 4)
    @cgtest u_sum_found(collect(1:20))
    for c in (true, false), d in (true, false)
        @cgtest u_phi(c, d, 7)
    end
    # unions of isbits values are not boxed (only the entry wrapper boxes the result)
    @test @filecheck begin
        @check_label "define internal"
        @check_not "julia.gc_alloc_obj"
        @check_label "define ptr addrspace(10) @jctest_entry"
        print(test_ir(u_maybe, (Bool, Int)))
    end
    @test @filecheck begin
        @check "phi { [8 x i8], i8, ptr addrspace(10) }"
        print(test_ir(u_phi, (Bool, Bool, Int)))
    end
end

@testset "constants keep their box" begin
    # an isbits constant in a union keeps the object of the constant as its box
    # (JuliaLang/julia#55045), as native code: boxing it allocates nothing
    @cgtest u_box_const(true)
    @cgtest u_box_const(false)
    p() = ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), cgrun(u_box_const, false))
    @test p() == p()
    @test @filecheck begin
        @check_label "define internal { [8 x i8], i8, ptr addrspace(10) } @julia_u_produce"
        @check "insertvalue { [8 x i8], i8, ptr addrspace(10) } %{{[0-9]+}}, i8 -12{{[0-9]}}, 1"
        test_ir(u_produce, (Bool, Int32))
    end
end

end
