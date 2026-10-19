# Builtins, through the JIT.

struct BPoint; x::Float64; y::Float64; end
struct BRef; n::Int; s::String; end
struct BNested; p::BPoint; r::BRef; end
mutable struct BMutable; x::Int; a::Any; r::BRef; end
mutable struct BPartial
    x::Int
    a::Any
    BPartial(x) = new(x)
end
struct BImmPartial
    a::Any
    b::Any
    BImmPartial(a) = new(a)
end
mutable struct BConst; const c::Int; v::Int; end

b_egal(x, y) = x === y
b_isa_int(x) = (isa(x, Int), isa(x, Integer), isa(x, Union{Int,Float64}), isa(x, AbstractString))
b_typeassert(x) = x::Integer
b_typeof(x) = typeof(x)
b_fields(p::BPoint) = (p.x, p.y)
b_nested(n::BNested) = (n.p.y, n.r.s, n.r)
b_mutable_get(m::BMutable) = (m.x, m.a, m.r)
b_mutable_set!(m::BMutable, x, a, r) = (m.x = x; m.a = a; m.r = r; m)
b_new_point(x, y) = BPoint(x, y)
b_new_ref(n, s) = BRef(n, s)
b_new_mutable(x, a, r) = BMutable(x, a, r)
b_new_partial(x) = BPartial(x)
b_partial_get(p::BPartial) = p.a
b_partial_defined(p::BPartial) = (isdefined(p, :x), isdefined(p, :a))
b_imm_partial(a) = BImmPartial(a)
b_imm_partial_get(p::BImmPartial) = p.b
b_tuple(x, y) = (x, (y, x), 1)
b_ifelse(c, x, y) = ifelse(c, x, y)
b_throw(x) = throw(x)
b_sizeof(x) = sizeof(x)
b_getglobal() = Core.getglobal(Base, :pi)
b_namedtuple(nt) = (nt.a, nt.b)
b_const_field(c::BConst) = (c.c, c.v)
b_tuple_index(t) = (t[1], t[2])

const B_EGAL_PAIRS = Any[
    (1, 1), (1, 2), (1, 1.0), (NaN, NaN), (0.0, -0.0), (1.0f0, 1.0f0), (true, true), (true, false),
    ('a', 'a'), (BPoint(1, 2), BPoint(1, 2)), (BPoint(1, 2), BPoint(1, 3)),
    (BRef(1, "a"), BRef(1, "a")), (BRef(1, "a"), BRef(1, "b")), ("abc", "abc"), ("abc", "abd"),
    (:a, :a), (:a, :b), (nothing, nothing), (nothing, 1), (Int, Int), (Int, Float64),
    (Vector{Int}, Vector{Int}), ([1], [1]), ((1, "a"), (1, "a")), (sin, sin), (sin, cos),
    (missing, missing), (BNested(BPoint(0, 1), BRef(2, "x")), BNested(BPoint(0, 1), BRef(2, "x"))),
]

@testset "builtins" begin

@testset "===" begin
    for (x, y) in B_EGAL_PAIRS
        @cgtest b_egal(x, y)
    end
    # mutable objects: identity
    m = BMutable(1, nothing, BRef(1, "a"))
    @test cgrun(b_egal, m, m)
    @test !cgrun(b_egal, m, BMutable(1, nothing, BRef(1, "a")))
    # compared as `Any`, by the runtime
    @test cgrun(b_egal, Any[BRef(1, "a")][1], Any[BRef(1, "a")][1])
end

@testset "isa, typeassert, typeof" begin
    for x in Any[1, 1.0, "s", 0x01, :sym, nothing, [1], BPoint(1, 2), Int8(3)]
        @cgtest b_isa_int(x)
        @cgtest b_typeassert(x)
        @cgtest b_typeof(x)
    end
end

@testset "new and fields" begin
    @cgtest b_fields(BPoint(1, 2))
    @cgtest b_nested(BNested(BPoint(1, 2), BRef(3, "s")))
    @cgtest b_new_point(1.0, 2.0)
    @cgtest b_new_ref(1, "one")
    @cgtest b_new_mutable(1, :a, BRef(2, "two"))
    @cgtest b_mutable_get(BMutable(1, "a", BRef(2, "b")))
    @cgtest b_mutable_set!(BMutable(1, "a", BRef(2, "b")), 7, [1, 2], BRef(3, "c"))
    @cgtest b_new_partial(3)
    @cgtest b_partial_get(BPartial(3))           # UndefRefError
    @cgtest b_partial_defined(BPartial(3))
    @cgtest b_imm_partial(1)
    @cgtest b_imm_partial_get(BImmPartial(1))    # UndefRefError
    @cgtest b_namedtuple((a=1, b="b"))
    @cgtest b_const_field(BConst(1, 2))
    @cgtest b_tuple_index((1, "a", 2.0))
    # the write barrier: young objects stored into an old one survive collections
    old = BMutable(0, nothing, BRef(0, ""))
    GC.gc(); GC.gc()
    for i in 1:200
        cgrun(b_mutable_set!, old, i, string(i), BRef(i, string(i)))
        i % 50 == 0 && GC.gc(false)
    end
    GC.gc()
    @test old.a == "200" && old.r == BRef(200, "200")
end

@testset "others" begin
    @cgtest b_tuple(1, "a")
    @cgtest b_tuple(BPoint(1, 2), nothing)
    for c in (true, false)
        @cgtest b_ifelse(c, 1, 2)
        @cgtest b_ifelse(c, "a", "b")
        @cgtest b_ifelse(c, BRef(1, "a"), BRef(2, "b"))
    end
    @cgtest b_throw(ErrorException("thrown"))
    @cgtest b_throw(3)
    @cgtest b_sizeof("abcd")
    @cgtest b_sizeof(1.0)
    @cgtest b_getglobal()
end

@testset "code" begin
    # these make no calls
    for (f, types) in ((b_fields, (BPoint,)), (b_new_point, (Float64, Float64)),
                       (b_new_mutable, (Int, Any, BRef)), (b_mutable_set!, (BMutable, Int, Any, BRef)),
                       (b_egal, (BPoint, BPoint)), (b_egal, (Symbol, Symbol)),
                       (b_isa_int, (Int,)), (b_tuple, (Int, String)), (b_sizeof, (String,)))
        @test @filecheck begin
            @check_not "julia.call"
            print(test_ir(f, types))
        end
    end
    # a write barrier for each reference stored into an object
    ir = test_ir(b_mutable_set!, (BMutable, Int, Any, BRef))
    if JuliaCodegen.CodegenConfig().dialect.barrier_flavour === :write_barrier
        @test @filecheck begin
            @check_count 2 "call void (ptr addrspace(10), ...) @julia.write_barrier("
            print(ir)
        end
    else
        @test @filecheck begin
            @check_count 2 "@julia.field_write_barrier.p11("
            print(ir)
        end
    end
    # the box of an object is compared by the runtime only if it isn't identical
    @test @filecheck begin
        @check "icmp ne ptr addrspace(10)"
        @check "@jl_egal__unboxed("
        print(test_ir(b_egal, (String, String)))
    end
end

end
