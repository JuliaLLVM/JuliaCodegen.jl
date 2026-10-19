# The LLVM types of Julia values: the layouts of inline types, which must agree with
# Julia's own layout of the type (`sizeof`, `fieldoffset`), and the types of the other
# representations.

"""
How an inline type is laid out in LLVM:

- `Aggregate`: an LLVM struct or array, one element per field that isn't a ghost;
- `VectorLayout`: a tuple of `VecElement`s that is an LLVM vector;
- `Unwrap`: a `VecElement`, which is its field, as in native code.
"""
@enum LayoutMode Aggregate VectorLayout Unwrap

"""
    JuliaCodegen.Layout

The LLVM layout of an inline Julia type: its LLVM type `llvm`, and for every Julia field
the 0-based LLVM element index (`-1` for ghosts) and how the field is stored.
"""
struct Layout
    llvm::LLVM.LLVMType
    fieldidx::Vector{Int}
    storage::Vector{FieldStorage}
    mode::LayoutMode
end

"""
Inline values are LLVM values, also first-class aggregates. Huge ones (an
`NTuple{1000000,UInt8}`) make instruction selection take forever, so their types are not
laid out inline (native code keeps aggregates in memory).
"""
const MAX_INLINE_BYTES = 4096

"""
    JuliaCodegen.Layouts(config::CodegenConfig)

The LLVM layouts of Julia types, for the LLVM context that is active when it is created:
LLVM types belong to a context, so this must only be used in that context.
"""
struct Layouts
    context::LLVM.Context
    datalayout::LLVM.DataLayout
    dialect::JuliaIR.Dialect
    cache::IdDict{Any,Layout}
end

Layouts(config::CodegenConfig) =
    Layouts(LLVM.context(), LLVM.DataLayout(config.target.datalayout), config.dialect,
            IdDict{Any,Layout}())

"""
    JuliaCodegen.primitive_nbits(T) -> Int

The number of bits of the primitive type `T`: from Julia 1.14 on, primitive types can
have fewer bits than their size (`primitive type U4 4 end`), which native code represents
as `i4`.
"""
function primitive_nbits(@nospecialize T)
    VERSION >= v"1.14-" || return 8 * sizeof(T)
    flags = unsafe_load(Ptr{Base.DataTypeLayout}(T.layout)).flags
    return 8 * sizeof(T) - Int((flags >> 8) & 0x7f)   # `unused_bits`
end

function primitive_llvm_type(@nospecialize T)
    T === Bool && return LLVM.Int8Type()
    T === Float16 && return LLVM.HalfType()
    T === Float32 && return LLVM.FloatType()
    T === Float64 && return LLVM.DoubleType()
    T === Core.BFloat16 && return LLVM.BFloatType()
    T <: Ptr && return T_ptr()
    T <: Core.LLVMPtr && return LLVM.PointerType(T.parameters[2])
    return LLVM.IntType(primitive_nbits(T))
end

# a `VecElement` of a primitive type of a power-of-two number of bytes, as LLVM vector
# elements must be (`jl_special_vector_alignment`)
function vector_element(@nospecialize E)
    (E isa DataType && E <: VecElement && fieldcount(E) == 1) || return false
    X = fieldtype(E, 1)
    isprimitivetype(X) || return false
    return ispow2(sizeof(X)) && primitive_nbits(X) == 8 * sizeof(X)
end

"Whether the tuple type `T` is an LLVM vector: a homogeneous tuple of `VecElement`s."
function is_vector_tuple(@nospecialize T)
    (T isa DataType && T <: Tuple && isconcretetype(T) && fieldcount(T) >= 1) || return false
    E = fieldtype(T, 1)
    return all(i -> fieldtype(T, i) === E, 2:fieldcount(T)) && vector_element(E)
end

"""
    JuliaCodegen.layout(ls::Layouts, T) -> Layout

The layout of the inline type `T`. Throws `Unsupported` when it can't be laid out inline,
or when the LLVM layout doesn't agree with Julia's.
"""
layout(ls::Layouts, @nospecialize(T)) = get!(() -> compute_layout(ls, T), ls.cache, T)

"""
    JuliaCodegen.value_type(ls::Layouts, T) -> Union{LLVM.LLVMType,Nothing}

The LLVM type of values of type `T` in their representation: the layout of inline types,
the union struct of unboxed unions (see [`union_type`](@ref JuliaCodegen.union_type)), a
tracked pointer for boxed values, and `nothing` for ghosts and `Union{}`.
"""
function value_type(ls::Layouts, @nospecialize T)
    k = repr_kind(T)
    k === Inline && return layout(ls, T).llvm
    k === UnionVal && return union_type(T)
    k === Boxed && return T_tracked()
    return nothing
end

function compute_layout(ls::Layouts, @nospecialize T)
    repr_kind(T) === Inline || throw(ArgumentError("$T is not an inline type"))
    sizeof(T) > MAX_INLINE_BYTES &&
        unsupported("an inline value of ", sizeof(T), " bytes (", T, ")")
    isprimitivetype(T) && return Layout(primitive_llvm_type(T), Int[], FieldStorage[], Aggregate)
    n = fieldcount(T)
    if T <: VecElement && !(fieldtype(T, 1) isa Union)
        s = field_storage(T, 1)
        s in (FieldInline, FieldPointer) || unsupported("the layout of ", T)
        ty = s === FieldInline ? layout(ls, fieldtype(T, 1)).llvm : T_tracked()
        return Layout(ty, [0], [s], Unwrap)
    end
    if is_vector_tuple(T)
        ty = LLVM.VectorType(layout(ls, fieldtype(fieldtype(T, 1), 1)).llvm, n)
        check_size(ls, T, ty)
        return Layout(ty, collect(0:n-1), fill(FieldInline, n), VectorLayout)
    end
    idx = Int[]
    storage = FieldStorage[]
    elements = LLVM.LLVMType[]
    for i in 1:n
        s = field_storage(T, i)
        s === FieldBlob && unsupported("the inline layout of ", T, ", which has a field of a type kept boxed")
        push!(storage, s)
        if s === FieldGhost
            push!(idx, -1)
        else
            push!(idx, length(elements))
            push!(elements, s === FieldInline ? layout(ls, fieldtype(T, i)).llvm :
                            s === FieldUnion ? LLVM.ArrayType(LLVM.Int8Type(), union_payload_size(fieldtype(T, i)) + 1) :
                            T_tracked())
        end
    end
    # as native code (`_julia_struct_to_llvm`): fields of one LLVM type, none a ghost or an
    # inline union, make an array
    homogeneous = !isempty(elements) && length(elements) == n &&
                  all(==(elements[1]), elements) && !(FieldUnion in storage)
    ty = isempty(elements) ? LLVM.StructType(LLVM.LLVMType[]) :
         homogeneous ? LLVM.ArrayType(elements[1], length(elements)) :
         LLVM.StructType(elements)
    if !isempty(elements) && !same_offsets(ls, T, ty, idx)
        # the target's data layout aligns a field differently than Julia does (e.g. `i128`
        # to 8 bytes on targets that don't say otherwise, where Julia aligns `Int128` to
        # 16): a packed struct with the fields at Julia's offsets, and explicit padding
        ty, idx = padded_struct(ls, T, idx, elements)
    end
    isempty(elements) || check_size(ls, T, ty)
    return Layout(ty, idx, storage, Aggregate)
end

# whether the LLVM aggregate `ty` has the size of `T`, and the fields of `T` (the elements
# `idx`) at Julia's offsets
function same_offsets(ls::Layouts, @nospecialize(T), ty::LLVM.LLVMType, idx::Vector{Int})
    dl = ls.datalayout
    LLVM.abi_size(dl, ty) == sizeof(T) || return false
    for i in 1:fieldcount(T)
        idx[i] < 0 && continue
        offset = ty isa LLVM.StructType ? LLVM.offsetof(dl, ty, idx[i] + 1) :
                 idx[i] * LLVM.abi_size(dl, ty.element_type)
        offset == fieldoffset(T, i) || return false
    end
    return true
end

# a packed struct of the `elements` of the fields of `T` (the elements `idx`) at Julia's
# offsets, with arrays of bytes as the padding; and the fields' elements in it
function padded_struct(ls::Layouts, @nospecialize(T), idx::Vector{Int},
                       elements::Vector{LLVM.LLVMType})
    dl = ls.datalayout
    padded = LLVM.LLVMType[]
    newidx = fill(-1, length(idx))
    offset = 0
    for i in sortperm(1:fieldcount(T); by=i -> fieldoffset(T, i))
        idx[i] < 0 && continue
        fo = Int(fieldoffset(T, i))
        fo < offset && unsupported("the layout of ", T, ": overlapping fields on this target")
        fo > offset && push!(padded, LLVM.ArrayType(LLVM.Int8Type(), fo - offset))
        newidx[i] = length(padded)
        el = elements[idx[i] + 1]
        push!(padded, el)
        offset = fo + Int(LLVM.abi_size(dl, el))
    end
    sizeof(T) > offset && push!(padded, LLVM.ArrayType(LLVM.Int8Type(), sizeof(T) - offset))
    return LLVM.StructType(padded; packed=true), newidx
end

function check_size(ls::Layouts, @nospecialize(T), ty::LLVM.LLVMType)
    sz = LLVM.abi_size(ls.datalayout, ty)
    sz == sizeof(T) || unsupported("the layout of ", T, ": its LLVM type has ", sz,
                                   " bytes instead of ", sizeof(T))
    return nothing
end

"""
    JuliaCodegen.union_type(U) -> LLVM.StructType

The LLVM type of values of the unboxed union `U`:

    {[N x i8] payload, i8 tindex, ptr addrspace(10) root_1, ..., root_R, ptr addrspace(10) box}

The low seven bits of `tindex` are the type index of the value's member (see
[`union_members`](@ref JuliaCodegen.union_members)), or 0 for a member that only lives
boxed; [`UNION_BOX_MARKER`](@ref JuliaCodegen.UNION_BOX_MARKER) says that `box` holds the
value's box. The payload holds the bytes of an unboxed member with its references left
out; the references, in the order of their offsets, are the roots (a split value, as
native code passes aggregates with references). Unions of ghosts have no `box`. This is
the `TIndex` representation of `jl_cgval_t`, as an SSA value, so that GC lowering tracks
its references like the fields of an inline struct.
"""
function union_type(@nospecialize U)
    elements = LLVM.LLVMType[LLVM.ArrayType(LLVM.Int8Type(), union_payload_size(U)),
                             LLVM.Int8Type()]
    append!(elements, fill(T_tracked(), union_nroots(U)))
    union_has_box(U) && push!(elements, T_tracked())
    return LLVM.StructType(elements)
end
