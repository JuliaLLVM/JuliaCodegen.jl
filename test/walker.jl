# Functions without calls: arguments, constants, control flow and phis, through the JIT.

struct WPoint; x::Float64; y::Float64; end
struct WRef; n::Int; s::String; end
struct WGhost; a::Int; g::Nothing; b::Int8; end
mutable struct WMutable; x::Int; end

w_identity(x) = x
w_constant_int() = 42
w_constant_float() = 1.5
w_constant_string() = "a string"
w_constant_tuple() = (1, 2.0, 'c')
const W_CONSTANT = WRef(3, "three")
w_constant_refs() = W_CONSTANT
w_constant_nothing() = nothing
w_select(c::Bool, x, y) = c ? x : y
w_second(x, y) = y
w_ghost_arg(::Nothing, x) = x
# a phi without any call around it
function w_phi(c::Bool, d::Bool, x, y)
    r = c ? x : y
    d && return x
    return r
end
function w_branches(a::Bool, b::Bool, x, y, z)
    if a
        r = x
    elseif b
        r = y
    else
        r = z
    end
    return r
end

@testset "walker" begin

@testset "identity of $(typeof(x))" for x in Any[1, -7, 0x12, 1.0, 1.5f0, Float16(2), true, false, 'x',
                                    Int128(2)^100, UInt8(255), Ptr{Int}(1234),
                                    (1, 2), (1, 2.5), (1, "two"), WPoint(1, 2), WRef(1, "s"),
                                    WGhost(1, nothing, 2), Some{Any}(:sym), Some(3),
                                    nothing, missing, sin, "string", :symbol, [1, 2, 3],
                                    WMutable(3), Int, Any[1, "a"], (a=1, b=2.0)]
    @cgtest w_identity(x)
end

@testset "constants" begin
    @cgtest w_constant_int()
    @cgtest w_constant_float()
    @cgtest w_constant_string()
    @cgtest w_constant_tuple()
    @cgtest w_constant_refs()
    @cgtest w_constant_nothing()
    # the same object, not a copy
    @test cgrun(w_constant_string) === w_constant_string()
    # objects are referenced through globals, not by address
    ir = test_ir(w_constant_string, ())
    @test @filecheck begin
        @check "@\"jl_global#{{[0-9]+}}\" = external global ptr"
        @check_not "inttoptr (i64 {{[0-9]+}} to ptr)"
        print(ir)
    end
end

@testset "control flow" begin
    for (c, x, y) in [(true, 1, 2), (false, 1, 2), (true, 1.0, 2.0), (false, "a", "b"),
                      (true, WPoint(1, 2), WPoint(3, 4)), (false, WRef(1, "a"), WRef(2, "b")),
                      (true, nothing, nothing), (false, :a, :b)]
        @cgtest w_select(c, x, y)
    end
    @cgtest w_second(1, 2.0)
    @cgtest w_ghost_arg(nothing, 3)
    for a in (true, false), b in (true, false)
        @cgtest w_branches(a, b, 1, 2, 3)
        @cgtest w_branches(a, b, "x", "y", "z")
    end
    for c in (true, false), d in (true, false)
        @cgtest w_phi(c, d, 1, 2)
        @cgtest w_phi(c, d, "x", "y")
        @cgtest w_phi(c, d, WRef(1, "a"), WRef(2, "b"))
        @cgtest w_phi(c, d, nothing, nothing)
    end
    @test @filecheck begin
        @check "phi i64 [ %{{[0-9]+}}, %L2 ], [ %{{[0-9]+}}, %L3 ]"
        print(test_ir(w_phi, (Bool, Bool, Int, Int)))
    end
    @test @filecheck begin
        @check "phi { i64, ptr addrspace(10) }"
        print(test_ir(w_phi, (Bool, Bool, WRef, WRef)))
    end
end

@testset "function attributes" begin
    # the attributes every native function has, but `julia.fsig` (and `optnone` of jlcall
    # wrappers), on the functions JuliaCodegen defines
    attrs(f) = Set(string(a) for a in collect(f.function_attributes)
                   if !occursin(r"julia\.fsig|optnone|noinline", string(a)))
    ir = native_module_ir(w_identity, Tuple{Int})
    native = @dispose ctx=Context() mod=parse(LLVM.Module, ir) begin
        attrs(only(f for f in mod.functions if startswith(f.name, "julia_")))
    end
    @dispose ctx=Context() mod=parse(LLVM.Module, (cgrun(w_identity, 1); test_ir(w_identity, (Int,)))) begin
        for f in mod.functions
            LLVM.isdeclaration(f) && continue
            @test attrs(f) == native
        end
    end
end

@testset "GC" begin
    # boxes of results survive collections
    @cgtest gc=true w_identity(WRef(10, "ten"))
    vals = [cgrun(w_identity, WRef(i, string(i))) for i in 1:1000]
    GC.gc()
    @test all(i -> vals[i] == WRef(i, string(i)), 1:1000)
end


end
