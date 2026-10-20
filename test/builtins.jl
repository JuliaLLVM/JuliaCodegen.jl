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
b_dynamic_index(t, i) = t[i]
b_dynamic_inbounds(t, i) = @inbounds t[i]
b_dynamic_const(i) = @inbounds (1.0f0, 2.0f0, 3.0f0, 4.0f0)[i]
b_dynamic_field(m, i) = getfield(m, i)
b_div(x, y) = div(x, y)
b_svec(x, y) = Core.svec(x, y, 1)
b_svec_len(s) = length(s)
b_memoryref(m, i) = Core.memoryrefnew(Core.memoryrefnew(m), i, true)
function b_undefvar(c)
    c && (x = 1)
    return x
end

const B_EGAL_PAIRS = Any[
    (1, 1), (1, 2), (1, 1.0), (NaN, NaN), (0.0, -0.0), (1.0f0, 1.0f0), (true, true), (true, false),
    ('a', 'a'), (BPoint(1, 2), BPoint(1, 2)), (BPoint(1, 2), BPoint(1, 3)),
    (BRef(1, "a"), BRef(1, "a")), (BRef(1, "a"), BRef(1, "b")), ("abc", "abc"), ("abc", "abd"),
    (:a, :a), (:a, :b), (nothing, nothing), (nothing, 1), (Int, Int), (Int, Float64),
    (Vector{Int}, Vector{Int}), ([1], [1]), ((1, "a"), (1, "a")), (sin, sin), (sin, cos),
    (missing, missing), (BNested(BPoint(0, 1), BRef(2, "x")), BNested(BPoint(0, 1), BRef(2, "x"))),
]

b_objects(x) = Any[x > 0, nothing, ()]
b_throw(x) = throw(ArgumentError(x))
b_throw_singleton() = throw(DivideError())

mutable struct B_Atomic
    @atomic n::Int
    @atomic f::Float64
    @atomic s::Int8
    @atomic r::Any
end
b_new() = B_Atomic(1, 1.5, Int8(3), "x")
b_inc(c) = ((@atomic c.n += 2), (@atomic c.n))
b_max(c) = ((@atomic c.f max 4.0), (@atomic c.f))
b_small(c) = ((@atomic c.s *= Int8(2)), (@atomic c.s))
b_ref(c) = ((@atomic c.r = (@atomic c.r) * "y"), (@atomic c.r))
b_refmod(c) = ((@atomic c.r *= "z"), (@atomic c.r))
b_bad(c) = (@atomic c.n += 0.5)          # (the result isn't an Int: TypeError)
mutable struct B_Plain; n::Int; end
b_plain(c) = Core.modifyfield!(c, :n, +, 1)   # (not atomic: an error from the runtime)
b_orders(c) = (getfield(c, :n, :monotonic), getfield(c, :f, :acquire), getfield(c, :r, :sequentially_consistent),
               getfield(c, :s, :not_atomic))   # (the last: ConcurrencyViolationError)

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
    # fields whose index is only known at run time
    for t in Any[(1, 2), (1.0f0, 2.0f0, 3.0f0, 4.0f0, 5.0f0), ("a", "b", "c", "d"), ("a", :b, 3),
                 (BPoint(1, 2), BPoint(3, 4), BPoint(5, 6), BPoint(7, 8)),
                 ntuple(i -> VecElement(Float32(i)), 4), (nothing, nothing), (7,)],
        i in (1, 2, 0, length(t) + 1)      # (out of bounds: BoundsError)
        @cgtest b_dynamic_index(t, i)
        1 <= i <= length(t) && @cgtest b_dynamic_inbounds(t, i)
    end
    @cgtest b_dynamic_const(3)
    @cgtest b_dynamic_field(BPoint(1, 2), 2)
    @cgtest b_dynamic_field(BMutable(1, "a", BRef(2, "b")), 2)
    @cgtest b_dynamic_field(BPartial(3), 2)        # UndefRefError
    @cgtest b_dynamic_field(BPartial(3), 3)        # BoundsError
    @cgtest b_memoryref(Memory{Int}(1:3), 4)       # BoundsError
    @cgtest b_div(1, 0)                            # DivideError
    @cgtest b_undefvar(true)
    @cgtest b_undefvar(false)                      # UndefVarError
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
    @cgtest b_svec("a", 2.0)
    @cgtest b_svec_len(Core.svec(1, "b", :c))
    @cgtest b_svec_len(Core.svec())
end

@testset "code" begin
    # these make no calls
    for (f, types) in ((b_fields, (BPoint,)), (b_new_point, (Float64, Float64)),
                       (b_new_mutable, (Int, Any, BRef)), (b_mutable_set!, (BMutable, Int, Any, BRef)),
                       (b_egal, (BPoint, BPoint)), (b_egal, (Symbol, Symbol)),
                       (b_isa_int, (Int,)), (b_tuple, (Int, String)), (b_sizeof, (String,)),
                       (b_svec, (String, Float64)), (b_svec_len, (Core.SimpleVector,)))
        @test @filecheck begin
            @check_not "julia.call"
            print(test_ir(f, types))
        end
    end
    # (unless --check-bounds=yes checks bounds in `@inbounds` too, throwing through a call)
    if Base.JLOptions().check_bounds != 1
        for types in ((NTuple{2,Int}, Int), (NTuple{4,Float32}, Int), (NTuple{4,String}, Int))
            @test @filecheck begin
                @check_not "julia.call"
                print(test_ir(b_dynamic_inbounds, types))
            end
        end
    end
    # an inline argument indexed at run time is read where it is, from the memory it is
    # passed in
    @test @filecheck begin
        @check_label "define internal float @julia_b_dynamic_inbounds"
        @check "ptr addrspace(11)"
        @check_not "alloca"
        @check "getelementptr inbounds float, ptr addrspace(11)"
        print(test_ir(b_dynamic_inbounds, (NTuple{8,Float32}, Int)))
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
    # a constant tuple indexed at run time is loaded from a constant global, as native
    # code's (which GPU back ends place in constant memory)
    @test @filecheck begin
        @check "@_j_const{{.*}} = private unnamed_addr constant [4 x float]"
        @check "load float, ptr"
        print(test_ir(b_dynamic_const, (Int,)))
    end
    # error paths throw through the runtime, as native code's (which GPU back ends lower),
    # rather than construct their exceptions
    for (f, types, callee) in ((b_dynamic_index, (NTuple{4,Float32}, Int), "@ijl_bounds_error_unboxed_int("),
                               (b_dynamic_index, (Tuple{String,Symbol}, Int), "@ijl_bounds_error_int("),
                               (b_memoryref, (Memory{Int}, Int), "@ijl_bounds_error_int("),
                               (b_partial_get, (BPartial,), "@ijl_throw("),
                               (b_div, (Int, Int), "@ijl_throw("),
                               (b_undefvar, (Bool,), "@ijl_undefined_var_error("))
        @test @filecheck begin
            @check_not "julia.call"
            @check "call void $callee"
            print(test_ir(f, types))
        end
    end
    # the box of an object is compared by the runtime only if it isn't identical
    @test @filecheck begin
        @check "icmp ne ptr addrspace(10)"
        @check "@jl_egal__unboxed("
        print(test_ir(b_egal, (String, String)))
    end
end

@testset "the runtime's objects" begin
    # `true`, `false`, `nothing`, `()` and `Core.svec()` through the runtime's globals, as
    # native code refers to them
    ir = test_ir(b_objects, (Int,))
    for name in ("jl_true", "jl_false", "jl_nothing", "jl_emptytuple")
        @test occursin("@$name = external constant ptr", ir)
    end
    @cgtest b_objects(1)
    @cgtest b_objects(-1)
end

@testset "throw" begin
    @cgtest b_throw("message")
    @cgtest b_throw_singleton()
    # through the runtime's `jl_throw`, as native code (which GPU compilers lower)
    for (f, types) in ((b_throw, (String,)), (b_throw_singleton, ()))
        @test @filecheck begin
            @check_label "define internal void @julia_"
            @check "call void @ijl_throw(ptr addrspace(12)"
            @check_not "@ijl_apply_generic"
            test_ir(f, types)
        end
    end
end

@testset "atomic field modifications" begin
    @cgtest b_inc(b_new())
    @cgtest b_max(b_new())
    @cgtest b_small(b_new())
    @cgtest b_ref(b_new())
    @cgtest b_refmod(b_new())
    @cgtest b_bad(b_new())
    @cgtest b_plain(B_Plain(1))
    @cgtest b_orders(b_new())
    # a loop of compare-and-exchange calling the operation, as native code
    @test @filecheck begin
        @check "load atomic i64"
        @check "cmpxchg ptr addrspace(11) %{{[0-9]+}}, i64 %{{[0-9]+}}, i64 %{{[0-9]+}} seq_cst monotonic"
        @check_not "@ijl_apply_generic"
        test_ir(b_inc, (B_Atomic,))
    end
end

end
