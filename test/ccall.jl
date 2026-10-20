# ccall, cglobal and GC.@preserve, through the JIT.

struct CDD; a::Float64; b::Float64; end
struct CIF; i::Cint; f::Cfloat; end
struct CFF; x::Cfloat; y::Cfloat; end
struct CCD; c::Cchar; d::Cdouble; end
struct CBig; a::Float64; b::Float64; c::Float64; end
struct CDiv; quot::Cint; rem::Cint; end
struct CLDiv; quot::Clong; rem::Clong; end
mutable struct CMut; a::Cint; b::Cint; end

# a small C library of aggregates by value, compiled when a C compiler is available
const LIBCABI = let lib = joinpath(mktempdir(), "libcabi." * Libdl.dlext)
    cc = Sys.which("cc")
    if cc !== nothing && !Sys.iswindows()
        run(`$cc -O2 -shared -fPIC -o $lib $(joinpath(@__DIR__, "c", "cabi.c"))`)
        lib
    else
        nothing
    end
end

cc_strlen(s) = ccall(:strlen, Csize_t, (Cstring,), s)
cc_sin(x) = ccall(:sin, Cdouble, (Cdouble,), x)
cc_libm(x) = ccall((:cos, Base.Math.libm), Cdouble, (Cdouble,), x)
cc_gc_safe(x) = @ccall gc_safe=true sin(x::Float64)::Float64
cc_div(a, b) = ccall(:div, CDiv, (Cint, Cint), a, b)
cc_ldiv(a, b) = ccall(:ldiv, CLDiv, (Clong, Clong), a, b)
cc_ptr(p, a, b) = ccall(p, Cint, (Cint, Cint), a, b)
cc_vararg(x::Cdouble) = (buf = zeros(UInt8, 32);
    n = ccall(:snprintf, Cint, (Ptr{UInt8}, Csize_t, Cstring, Cdouble...), buf, 32, "%4.2f", x);
    String(buf[1:n]))
cc_ref(x) = (r = Ref(x); ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), r, 0, sizeof(x)); r[])
cc_refarg(x::Int) = (r = Ref(x); ccall(:jl_typeof_str, Cstring, (Any,), r); r[])
cc_any(x) = ccall(:jl_typeof_str, Cstring, (Any,), x) |> unsafe_string
cc_mutable(a) = ccall(:abs, Cint, (Cint,), a)
cc_cglobal() = unsafe_load(cglobal(:jl_n_threads, Cint)) > 0
cc_pointer(x) = pointer_from_objref(x) == pointer_from_objref(x)
cc_preserve(v::Vector{Int}) = GC.@preserve v unsafe_load(pointer(v), 2)
cc_string_ptr(s::String) = unsafe_load(pointer(s))
cc_bad_target(x) = ccall(x, Cint, ())             # TypeError: not a pointer
cc_bad_arg(x) = ccall(:abs, Cint, (Cint,), x)     # TypeError for a non-Cint
cc_parse(s) = parse(Float64, s)
if LIBCABI !== nothing
    @eval begin
        cc_dd(v, s) = ccall((:dd_scale, $LIBCABI), CDD, (CDD, Cdouble), v, s)
        cc_if(v) = ccall((:if_bump, $LIBCABI), CIF, (CIF,), v)
        cc_ff(v) = ccall((:ff_swap, $LIBCABI), CFF, (CFF,), v)
        cc_cd(v) = ccall((:cd_mix, $LIBCABI), CCD, (CCD,), v)
        cc_big(v, w) = ccall((:big_sum, $LIBCABI), CBig, (CBig, CBig), v, w)
        cc_dot(v, w) = ccall((:big_dot, $LIBCABI), Cdouble, (CBig, CBig), v, w)
    end
end

const CC_V4 = NTuple{4,VecElement{Float32}}
cc_sqrt(x) = ccall("llvm.sqrt.f64", llvmcall, Float64, (Float64,), x)
cc_ctpop(x) = ccall("llvm.ctpop.i64", llvmcall, Int64, (Int64,), x)
cc_fma(a, b, c) = ccall("llvm.fma.v4f32", llvmcall, CC_V4, (CC_V4, CC_V4, CC_V4), a, b, c)
cc_donothing(x) = (ccall("llvm.donothing", llvmcall, Cvoid, ()); x)
cc_unknown() = (ccall("llvm.jctest.nonexistent", llvmcall, Cvoid, ()); nothing)
cc_not_intrinsic(x) = ccall("jctest_function", llvmcall, Int, (Int,), x)
cc_extern(s) = GC.@preserve s Int(ccall("extern strlen", llvmcall, Csize_t, (Ptr{UInt8},), pointer(s)))
cc_powi(x, n) = ccall("llvm.powi", llvmcall, Float64, (Float64, Int32), x, n)

@testset "ccall" begin

@testset "calls" begin
    @cgtest cc_strlen("abcd")
    @cgtest cc_sin(0.5)
    @cgtest cc_libm(0.5)
    @cgtest cc_gc_safe(0.5)
    @cgtest cc_div(Cint(17), Cint(5))
    @cgtest cc_ldiv(-17, 5)
    @cgtest cc_ptr(cglobal(:abs), Cint(-3), Cint(0))
    @cgtest cc_vararg(3.14159)
    @cgtest cc_ref(42)
    @cgtest cc_any(1.5)
    @cgtest cc_any("s")
    @cgtest cc_mutable(Cint(-7))
    @cgtest cc_cglobal()
    @cgtest cc_pointer(Ref(1))
    @cgtest cc_preserve([1, 2, 3])
    @cgtest cc_string_ptr("abc")
    @cgtest cc_bad_target(:abs)
    @cgtest cc_bad_arg(1.5)
end

@testset "aggregates by value" begin
    if LIBCABI === nothing
        @test_skip "no C compiler"
    else
        @cgtest cc_dd(CDD(1.5, -2.0), 2.0)
        @cgtest cc_if(CIF(Cint(3), 1.5f0))
        @cgtest cc_ff(CFF(1f0, 2f0))
        @cgtest cc_cd(CCD(Cchar(7), 2.5))
        @cgtest cc_big(CBig(1, 2, 3), CBig(10, 20, 30))
        @cgtest cc_dot(CBig(1, 2, 3), CBig(10, 20, 30))
    end
end

@testset "code" begin
    # a symbol in the runtime's namespace is referenced by name (its `ijl_` alias for
    # the runtime's own), one of another library through a lookup on first use; neither
    # embeds an address
    # (`strlen` is in the runtime's namespace on some builds, then declared by name)
    @test @filecheck begin
        @check_not "inttoptr (i64 {{[1-9][0-9]+}} to ptr)"
        @check "strlen"
        print(test_ir(cc_strlen, (String,)))
    end
    @test @filecheck begin
        @check "declare {{.*}}@ijl_typeof_str("
        print(test_ir(cc_any, (Float64,)))
    end
    @test @filecheck begin
        @check_not "inttoptr (i64 {{[1-9][0-9]+}} to ptr)"
        @check "call ptr @ijl_load_and_lookup("
        print(test_ir(cc_libm, (Float64,)))
    end
end

@testset "llvmcall convention" begin
    @cgtest cc_sqrt(2.25)
    @cgtest cc_ctpop(0b101101)
    v(x...) = map(VecElement, Float32.(x))
    @cgtest cc_fma(v(1, 2, 3, 4), v(2, 2, 2, 2), v(1, 1, 1, 1))
    @cgtest cc_donothing(3)
    @test @filecheck begin
        @check "call double @llvm.sqrt.f64(double"
        test_ir(cc_sqrt, (Float64,))
    end
    # an intrinsic LLVM doesn't know, or not an intrinsic: an error at run time, as native
    # code ("llvmcall only supports intrinsic calls")
    @cgtest cc_unknown()
    @cgtest cc_not_intrinsic(1)
    @test occursin("call void @ijl_error(", test_ir(cc_unknown, ()))
    # an external function, by name
    @cgtest cc_extern("four")
    @test occursin("declare i64 @strlen(ptr)", test_ir(cc_extern, (String,)))
    # the base name of an overloaded intrinsic: the overload of the signature
    @cgtest cc_powi(1.5, Int32(3))
    @test occursin("call double @llvm.powi.f64.i32(double", test_ir(cc_powi, (Float64, Int32)))
end

end
