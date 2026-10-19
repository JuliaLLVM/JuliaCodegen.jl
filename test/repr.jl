struct Padded; a::Int8; b::Int64; c::Int16; end
struct Nested; p::Padded; x::Float32; end
struct WithGhost; a::Int; n::Nothing; b::Float64; end
struct WithRef; a::Int; s::String; end
struct WithUnionField; x::Union{Int,Nothing}; end
mutable struct MutableHolder; x::Int; end
primitive type Prim24 24 end

# the layouts of a corpus of inline types against Julia's own layout, and against the
# LLVM types native code uses for them: the return type of an identity function, or the
# type of its `sret` result
const INLINE_TYPES = Any[
    Int8, Int16, Int32, Int64, Int128, UInt8, UInt64, UInt128, Float16, Float32, Float64,
    Bool, Char, Ptr{Int}, Core.BFloat16, Prim24,
    Tuple{Int,Float64}, NTuple{3,Int}, NTuple{2,Float32}, Tuple{Bool,Int8,Int64},
    NTuple{4,VecElement{Float32}}, NTuple{2,VecElement{Int64}}, VecElement{Int32},
    ComplexF64, Complex{Int32}, Pair{Int,Float64}, Some{Int}, Padded, Nested, WithGhost,
    Tuple{Nothing,Int}, Some{Any}, WithRef, Tuple{Int,String,Float64}, NTuple{2,String},
]

identity_probe(x) = x

function native_value_type(@nospecialize T)
    ir = native_module_ir(identity_probe, Tuple{T})
    @dispose ctx=Context() mod=parse(LLVM.Module, ir) begin
        f = only(f for f in mod.functions if startswith(f.name, "julia_"))
        rt = LLVM.return_type(f.function_type)
        rt isa LLVM.VoidType || return string(rt)
        m = match(r"sret\(([^()]+)\)", ir)
        return m === nothing ? nothing : m[1]
    end
end

@testset "representation" begin

JC = JuliaCodegen

@testset "classification" begin
    for (T, k) in [(Int, JC.Inline), (Bool, JC.Inline), (Float16, JC.Inline),
                   (Ptr{Int}, JC.Inline), (Tuple{Int,Float64}, JC.Inline),
                   (Some{Any}, JC.Inline), (WithRef, JC.Inline), (WithGhost, JC.Inline),
                   (Prim24, JC.Inline),
                   (Nothing, JC.Ghost), (typeof(sin), JC.Ghost), (Tuple{}, JC.Ghost),
                   (Union{Nothing,Int}, JC.UnionVal), (Union{Int,String}, JC.UnionVal),
                   (Union{Nothing,Missing}, JC.UnionVal),
                   (Union{Nothing,String}, JC.Boxed), (Any, JC.Boxed), (String, JC.Boxed),
                   (Vector{Int}, JC.Boxed), (MutableHolder, JC.Boxed),
                   (WithUnionField, JC.Boxed), (Integer, JC.Boxed),
                   (Union{}, JC.Bottom)]
        @test JC.repr_kind(T) === k
    end
    # the empty `Memory` is an instance of a mutable type, not a singleton
    @test JC.repr_kind(Memory{Int}) === JC.Boxed
    @test JC.repr_kind(isdefined(Core, :TypeEgal) ? Core.TypeEgal{Union{}} : Type{Union{}}) === JC.Ghost
    @test JC.ghost_value(Nothing) == Some(nothing)
    @test JC.ghost_value(typeof(sin)) == Some(sin)

    # `Type{X}` is a singleton when only `X` is an instance of it
    if isdefined(Core, :TypeEgal)
        @test JC.ghost_value(Core.TypeEgal{Int}) == Some(Int)
        @test JC.ghost_value(Type{Int}) === nothing
    else
        @test JC.ghost_value(Type{Int}) == Some(Int)
        @test JC.ghost_value(Type{Vector{Int}}) == Some(Vector{Int})
    end
    @test JC.ghost_value(Type{Vector}) === nothing           # `Vector{T} where T` and others

    @test JC.field_storage(Padded, 1) === JC.FieldInline
    @test JC.field_storage(WithGhost, 2) === JC.FieldGhost
    @test JC.field_storage(WithRef, 2) === JC.FieldPointer
    @test JC.field_storage(WithUnionField, 1) === JC.FieldUnion
    @test !JC.has_references(Padded)
    @test JC.has_references(WithRef)
    @test JC.has_references(Tuple{Int,Some{Any}})
end

@testset "unions" begin
    U = Union{Nothing,Int,Float32}
    @test JC.union_members(U) == Base.uniontypes(U)
    @test JC.union_tindex(U, Int) == findfirst(==(Int), JC.union_members(U))
    @test_throws JC.Unsupported JC.union_tindex(U, String)
    @test JC.union_payload_size(U) == 8
    @test JC.union_nroots(U) == 0
    @test JC.is_bits_union(U)
    @test !JC.is_bits_union(Union{Nothing,Some{Any}})
    @test JC.union_nroots(Union{Nothing,Some{Any},Tuple{Int,String}}) == 1
    # a member made of references only lives in the roots
    @test JC.union_payload_size(Union{Nothing,Some{Any}}) == 0
    @test JC.union_payload_size(Union{Nothing,Tuple{Int,String}}) == 16
    @dispose ctx=Context() begin
        @test string(JC.union_type(U)) == "{ [8 x i8], i8, ptr addrspace(10) }"
        @test string(JC.union_type(Union{Nothing,Missing})) == "{ [0 x i8], i8 }"
        @test string(JC.union_type(Union{Int,Some{Any},String})) ==
              "{ [8 x i8], i8, ptr addrspace(10), ptr addrspace(10) }"
    end
end

struct R_PadPair; a::Float32; b::Int128; end
struct R_Nested; x::R_PadPair; y::Int8; end
r_padded(p::R_PadPair) = R_Nested(R_PadPair(p.a + 1f0, p.b), Int8(3))

# targets whose data layout aligns a field differently than Julia: SPIR-V's aligns `i128`
# to 8 bytes, Julia `Int128` to 16
@testset "layouts on other targets" begin
    triple = "spirv64-unknown-unknown"
    datalayout = "e-i64:64-v16:16-v24:32-v32:32-v48:64-v96:128-v192:256-v256:256-v512:512-v1024:1024-G1-ni:10:11:12:13"
    config = JC.CodegenConfig(; target=JC.Target(; triple, datalayout), on_unsupported=:error,
                              on_internal_error=:error)
    @dispose ctx=Context() begin
        ls = JC.Layouts(config)
        dl = ls.datalayout
        lay = JC.layout(ls, R_PadPair)
        @test string(lay.llvm) == "<{ float, [12 x i8], i128 }>"
        @test lay.fieldidx == [0, 2]
        lay = JC.layout(ls, R_Nested)
        @test LLVM.abi_size(dl, lay.llvm) == sizeof(R_Nested)
        @test LLVM.offsetof(dl, lay.llvm, lay.fieldidx[2] + 1) == fieldoffset(R_Nested, 2)
        # the host's layout needs no padding
        host = JC.Layouts(JC.CodegenConfig())
        Sys.ARCH === :x86_64 && @test string(JC.layout(host, R_PadPair).llvm) == "{ float, i128 }"
    end
    # code with such values
    @test @filecheck begin
        @check "<{ float, [12 x i8], i128 }>"
        test_module_ir(r_padded, (R_PadPair,); triple, datalayout)
    end
end

@testset "layouts" begin
    config = JC.CodegenConfig()
    @dispose ctx=Context() begin
        ls = JC.Layouts(config)
        dl = ls.datalayout
        for T in INLINE_TYPES
            @testset "$T" begin
                lay = JC.layout(ls, T)
                if isprimitivetype(T)
                    # an integer of the type's bits, which may be fewer than its size
                    @test LLVM.storage_size(dl, lay.llvm) == cld(JC.primitive_nbits(T), 8) <= sizeof(T)
                else
                    @test LLVM.abi_size(dl, lay.llvm) == sizeof(T)
                end
                if lay.llvm isa LLVM.StructType
                    for i in 1:fieldcount(T)
                        lay.fieldidx[i] < 0 && continue
                        @test LLVM.offsetof(dl, lay.llvm, lay.fieldidx[i] + 1) == fieldoffset(T, i)
                    end
                end
                @test JC.layout(ls, T) === lay
                native = native_value_type(T)
                native === nothing || @test string(lay.llvm) == native
            end
        end

        @test JC.layout(ls, NTuple{4,VecElement{Float32}}).mode === JC.VectorLayout
        @test JC.layout(ls, VecElement{Int32}).mode === JC.Unwrap
        @test string(JC.layout(ls, WithGhost).llvm) == "{ i64, double }"
        @test JC.layout(ls, WithGhost).fieldidx == [0, -1, 1]
        @test JC.value_type(ls, Nothing) === nothing
        @test JC.value_type(ls, Any) == JC.T_tracked()
        @test JC.value_type(ls, Union{Nothing,Int}) == JC.union_type(Union{Nothing,Int})
        @test_throws "an inline value of 8000 bytes" JC.layout(ls, NTuple{1000,Int})
        @test_throws ArgumentError JC.layout(ls, Vector{Int})
    end
    @test JC.primitive_nbits(Prim24) == 24
    if VERSION >= v"1.14-"
        # primitive types with fewer bits than bytes
        Core.eval(Main, :(primitive type Prim4 4 end))
        @test JC.primitive_nbits(Main.Prim4) == 4
        @dispose ctx=Context() begin
            @test string(JuliaCodegen.layout(JuliaCodegen.Layouts(config), Main.Prim4).llvm) == "i4"
        end
    end
end

@testset "values" begin
    @dispose ctx=Context() begin
        v = JC.ghost(Nothing, nothing)
        @test v.kind === JC.Ghost && JC.isconstant(v) && JC.constant_value(v) === nothing
        @test JC.bottom().kind === JC.Bottom
        c = LLVM.ConstantInt(Int64(3))
        i = JC.inline(Int, c; constant=Some(3))
        @test i.kind === JC.Inline && JC.constant_value(i) == 3 && i.V == c
        @test sprint(show, i) == "CGVal(Inline, Int64, constant=3, i64)"
        @test !JC.isconstant(JC.inline(Int, c))
    end
end

end
