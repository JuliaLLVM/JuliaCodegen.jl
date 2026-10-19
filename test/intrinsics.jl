# Intrinsics, and the calls that are still dynamic, through the JIT.

i_arith(x, y) = (x + y, x - y, x * y)
i_compare(x, y) = (x == y, x != y, x < y, x <= y, x > y, x >= y)
i_bits(x, y) = (x & y, x | y, x ⊻ y, ~x)
i_unary(x) = (-x, abs(x), count_ones(x), leading_zeros(x), trailing_zeros(x), bswap(x))
i_shifts(x, n) = (x << n, x >> n, x >>> n)
i_divrem(x, y) = (div(x, y), rem(x, y))
i_fdivrem(x, y) = (x / y, rem(x, y))
i_float_unary(x) = (-x, abs(x), floor(x), ceil(x), trunc(x), isnan(x), copysign(x, -1.0))
i_fma(x, y, z) = (fma(x, y, z), muladd(x, y, z))
i_sqrt(x) = sqrt(x)
i_convert(::Type{T}, x) where {T} = T(x)
i_reinterpret(::Type{T}, x) where {T} = reinterpret(T, x)
i_flipsign(x, y) = flipsign(x, y)
i_fpiseq(x, y) = x === y
i_checked(x, y) = (Core.Intrinsics.checked_sadd_int(x, y), Core.Intrinsics.checked_smul_int(x, y))
i_checked_add(x, y) = Base.checked_add(x, y)
i_pointer(p::Ptr{Int}, i) = (unsafe_store!(p, unsafe_load(p, i) + 1, i); unsafe_load(p, i))
i_fence() = (Core.Intrinsics.atomic_fence(:sequentially_consistent); nothing)
i_fence2() = (Core.Intrinsics.atomic_fence(:sequentially_consistent, :system); nothing)
# an intrinsic with the wrong number of arguments, which inference knows throws
i_bad_intrinsic(x) = Core.Intrinsics.add_int(x)
i_fast(x, y) = (Base.FastMath.mul_fast(x, y), Base.FastMath.div_fast(x, y),
                Base.FastMath.min_fast(x, y), Base.FastMath.max_fast(x, y), Base.FastMath.sqrt_fast(x),
                Base.FastMath.lt_fast(x, y), Base.FastMath.neg_fast(x))
i_llvmcall(x::Int32) = Base.llvmcall("%r = add i32 %0, 1\nret i32 %r", Int32, Tuple{Int32}, x)
# (pointers are integers of their size in the IR, as native code passes them)
i_llvmcall_load(p::Ptr{Int32}) = Base.llvmcall("""
    %p = inttoptr i64 %0 to i32*
    %v = load i32, i32* %p, align 4
    ret i32 %v""", Int32, Tuple{Ptr{Int32}}, p)
i_llvmcall_ptr(p::Ptr{Int32}) = Base.llvmcall("%q = add i64 %0, 4\nret i64 %q", Ptr{Int32}, Tuple{Ptr{Int32}}, p)
i_llvmcall_ptrs(v::Vector{Int32}) = GC.@preserve v (i_llvmcall_load(pointer(v)), i_llvmcall_ptr(pointer(v)) - pointer(v))
i_poly(x) = 3x^2 - 2x + 1
i_loop(n) = (s = 0; for i in 1:n; s += i; end; s)
i_dynamic(f, x) = f(x)

const INTS = (Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128)
const FLOATS = (Float16, Float32, Float64)

@testset "intrinsics" begin

@testset "integers $T" for T in INTS
    for (x, y) in ((T(7), T(3)), (typemax(T), T(1)), (typemin(T), T(2)), (T(0), T(5)))
        @cgtest i_arith(x, y)
        @cgtest i_compare(x, y)
        @cgtest i_bits(x, y)
        @cgtest i_unary(x)
        @cgtest i_divrem(x, y)
        @cgtest i_flipsign(x, y)
    end
    @cgtest i_divrem(T(1), T(0))                         # DivideError
    T <: Signed && @cgtest i_divrem(typemin(T), T(-1))   # overflow
    for n in (0, 1, 7, 8 * sizeof(T) - 1, 8 * sizeof(T), 200, -1, -200)
        @cgtest i_shifts(T(0x5a), n)
    end
end

@testset "floats $T" for T in FLOATS
    for (x, y) in ((T(1.5), T(-2.25)), (T(Inf), T(1)), (T(NaN), T(0)), (T(-0.0), T(0.0)))
        @cgtest i_arith(x, y)
        @cgtest i_compare(x, y)
        @cgtest i_fdivrem(x, y)
        @cgtest i_float_unary(x)
        @cgtest i_fpiseq(x, y)
        @cgtest i_fma(x, y, T(0.5))
    end
    @cgtest i_sqrt(T(2))
    @cgtest i_sqrt(T(-1))                                # DomainError
end

@testset "conversions" begin
    @cgtest i_convert(Int64, Int8(-3))
    @cgtest i_convert(UInt8, 255)
    @cgtest i_convert(UInt8, 256)                        # InexactError
    @cgtest i_convert(Int32, typemax(Int64))
    @cgtest i_convert(Float64, 3)
    @cgtest i_convert(Float32, 1.0e100)
    @cgtest i_convert(Float64, 1.5f0)
    @cgtest i_convert(Float16, 3)                        # (the runtime rounds)
    @cgtest i_convert(Int, 2.0)
    @cgtest i_convert(Int, 2.5)                          # InexactError
    @cgtest i_reinterpret(UInt64, -1.0)
    @cgtest i_reinterpret(Float32, 0x3f800000)
    @cgtest i_reinterpret(Int8, true)
    @cgtest i_reinterpret(Bool, 0x01)
    @cgtest i_reinterpret(UInt, Ptr{Int}(16))
end

@testset "checked arithmetic" begin
    @cgtest i_checked(1, 2)
    @cgtest i_checked(typemax(Int), 2)
    @cgtest i_checked_add(typemax(Int), 1)               # OverflowError
end

@testset "pointers, fences, llvmcall" begin
    v = [1, 2, 3]
    GC.@preserve v begin
        @test cgrun(i_pointer, pointer(v), 2) == 3
        @test v == [1, 3, 3]
    end
    # (the scope argument exists from Julia 1.14 on; the other form throws)
    @cgtest i_fence()
    @cgtest i_fence2()
    @cgtest i_bad_intrinsic(1)
    @cgtest i_llvmcall(Int32(41))
    @cgtest i_fast(2.0f0, 8.0f0)
    # the fast-math flags of native code
    @test @filecheck begin
        @check "fmul fast float"
        @check "fdiv fast float"
        @check "call fast float @llvm.minimum.f32"
        @check "call fast float @llvm.maximum.f32"
        @check "call fast float @llvm.sqrt.f32"
        @check "fcmp fast olt float"
        test_ir(i_fast, (Float32, Float32))
    end
    @cgtest i_llvmcall_ptrs(Int32[7, 8])
end

@testset "code" begin
    @cgtest i_poly(10)
    @cgtest i_poly(-2.5)
    @cgtest i_flipsign(-3, 2)
    @cgtest i_loop(100)
    @cgtest i_dynamic(sin, 1.0)
    @cgtest i_dynamic(x -> x + 1, 2)
    # arithmetic on known types makes no calls (builtins, e.g. the `tuple` of a result,
    # are still dynamic calls)
    for (f, types) in ((i_poly, (Int,)), (i_poly, (Float64,)), (i_flipsign, (Int, Int)))
        @test @filecheck begin
            @check_not "julia.call"
            print(test_ir(f, types))
        end
    end
    # calls of unknown functions are dynamic, and invokes go through jl_invoke
    @test @filecheck begin
        @check "call ptr addrspace(10) (ptr, ptr addrspace(10), ...) @julia.call(ptr @ijl_apply_generic"
        print(test_ir(i_dynamic, (Any, Int)))
    end
    @test @filecheck begin
        @check "@julia.call2(ptr @ijl_invoke"
        print(test_ir(i_checked_add, (Int, Int)))
    end
end

end
