# How Julia values are represented in generated code, as in the C++ code generator
# (`jl_cgval_t`).

"""
    JuliaCodegen.Repr

How values of a type are represented in generated code (see
[`repr_kind`](@ref JuliaCodegen.repr_kind)), as in the C++ code generator's `jl_cgval_t`:

- `Ghost`: values of singleton and zero-size types have no run-time representation;
  the value is known at compile time (`nothing`, `typeof(sin)`, a unique `Type{X}`).
- `Inline`: values of concrete immutable inline-allocated types are kept unboxed, as
  LLVM values: primitive types, and structs and tuples whose fields are inline
  themselves or references to objects (tracked pointers, `ptr addrspace(10)`).
- `UnionVal`: values of a union with members that can be unboxed: a payload, a type
  index, the references of the members and a box for members that only exist boxed
  (see [`union_type`](@ref JuliaCodegen.union_type)).
- `Boxed`: everything else, a tracked pointer to an object with a type tag.
- `Bottom`: no value (code after a call that never returns).
"""
@enum Repr Ghost Inline UnionVal Boxed Bottom

"""
    JuliaCodegen.unique_type_parameter(T) -> Union{Some,Nothing}

The `X` of a `Type{X}` that only `X` is an instance of, or `nothing`. A `Type{X}` is keyed by
type equality, so it can have several instances (`Dict{K,V} where {V,K}` for
`Type{Dict}`); only types with a unique representation have one (`is_uniquerep_Type` in
the C++ code generator). From Julia 1.14 on, those are the `Core.TypeEgal{X}`.
"""
function unique_type_parameter(@nospecialize T)
    if isdefined(Core, :TypeEgal)
        Base.isTypeEgal(T) || return nothing
        return Some(Base.type_parameter(T))
    end
    (T isa DataType && T.name === Type.body.name) || return nothing
    X = T.parameters[1]
    has_unique_rep(X) || return nothing
    return Some(X)
end

# `type_has_unique_rep` in `src/codegen.cpp` of Julia 1.12 and 1.13
function has_unique_rep(@nospecialize X)
    X === typeof(Union{}) && return false
    X === Union{} && return true
    X isa TypeVar && return false
    X isa Type || return true          # a value that is not a type
    isconcretetype(X) && return true
    if X isa DataType && X.name !== Tuple.name
        return all(has_unique_rep, X.parameters)
    end
    return false
end

"""
    JuliaCodegen.ghost_value(T) -> Union{Some,Nothing}

The only value of type `T`, if `T` is a singleton type (`Some(value)`), else `nothing`.
"""
function ghost_value(@nospecialize T)
    X = unique_type_parameter(T)
    X === nothing || return X
    T isa DataType || return nothing
    # mutable types can have an `instance` too: the empty `Memory{T}`
    !ismutabletype(T) && isdefined(T, :instance) && return Some(T.instance)
    return nothing
end

"""
How a field is stored in its parent object (`field_storage`):

- `FieldGhost`: not at all (a zero-size type);
- `FieldInline`: inline, in the representation of the field's type;
- `FieldUnion`: inline as an isbits union (payload bytes and a selector byte);
- `FieldBlob`: inline, but of a type whose values are kept boxed (one with an inline union
  field somewhere inside): its bytes are copied to and from boxes;
- `FieldPointer`: as a reference to an object.
"""
@enum FieldStorage FieldGhost FieldInline FieldUnion FieldBlob FieldPointer

"""
    JuliaCodegen.field_storage(FT) -> FieldStorage
    JuliaCodegen.field_storage(T, i) -> FieldStorage

How a field of declared type `FT` (or field `i` of `T`) is stored in its parent.
"""
function field_storage(@nospecialize FT)
    Base.allocatedinline(FT) || return FieldPointer
    if FT isa Union
        is_bits_union(FT) ||
            unsupported("an inline field of type ", FT)
        return FieldUnion
    end
    sizeof(FT) == 0 && return FieldGhost
    inline_representable(FT) || return FieldBlob
    return FieldInline
end

function field_storage(@nospecialize(T), i::Int)
    FT = fieldtype(T, i)
    # an atomic field whose type is a union is a reference (`jl_compute_field_offsets` only
    # inlines atomic fields of a single concrete type)
    if FT isa Union && T isa DataType && ismutabletype(T) && Base.isfieldatomic(T, i)
        return FieldPointer
    end
    return field_storage(FT)
end

"""
    JuliaCodegen.repr_kind(T) -> Repr

The representation of values of type `T`.
"""
function repr_kind(@nospecialize T)
    T === Union{} && return Bottom
    ghost_value(T) === nothing || return Ghost
    is_unboxable_union(T) && return UnionVal
    if T isa DataType && isconcretetype(T) && !ismutabletype(T) && Base.allocatedinline(T)
        inline_representable(T) && return Inline
    end
    return Boxed
end

# Whether values of the inline-allocated type `T` can be kept inline: not if a field
# (also of a field) is an inline union, which LLVM aggregates can't express.
function inline_representable(@nospecialize T)
    isprimitivetype(T) && return true
    for i in 1:fieldcount(T)
        FT = fieldtype(T, i)
        if Base.allocatedinline(FT)
            FT isa Union && return false
            sizeof(FT) == 0 && continue
            FT isa DataType && isconcretetype(FT) && inline_representable(FT) || return false
        end
    end
    return true
end

"Whether values of the inline type `T` contain references to objects."
function has_references(@nospecialize T)
    isprimitivetype(T) && return false
    for i in 1:fieldcount(T)
        s = field_storage(T, i)
        s === FieldPointer && return true
        s in (FieldInline, FieldBlob) && has_references(fieldtype(T, i)) && return true
    end
    return false
end

"The number of references in the layout of the concrete type `T`."
npointers(@nospecialize T) =
    Int(unsafe_load(Ptr{Base.DataTypeLayout}(T.layout)).npointers)

## unions

"""
The marker in the type index of an unboxed union whose value also exists boxed.
"""
const UNION_BOX_MARKER = 0x80

# a member type that an unboxed union can hold: a ghost, or an inline type (with `bits`,
# only pointer-free ones)
function union_member_ok(@nospecialize(M); bits::Bool=false)
    (M isa DataType && isconcretetype(M)) || return false
    k = repr_kind(M)
    k === Ghost && return true
    k === Inline || return false
    return !bits || isbitstype(M)
end

"""
    JuliaCodegen.union_members(U) -> Vector{Any}

The members of the union `U` that live unboxed, in the order of their type indices
(from 1; native `for_each_uniontype_small`).
"""
union_members(@nospecialize U) = Any[M for M in Base.uniontypes(U) if union_member_ok(M)]

"Whether `U` has members that only live boxed (abstract types, mutable types, ...)."
union_has_boxed(@nospecialize U) = any(M -> !union_member_ok(M), Base.uniontypes(U))

"""
    JuliaCodegen.is_unboxable_union(U)

Whether values of the union `U` are represented unboxed: `U` has members that can live
unboxed, and as in native code, a union whose unboxed members carry no data alongside
boxed members (`Union{Nothing,String}`) is just boxed.
"""
function is_unboxable_union(@nospecialize U)
    U isa Union || return false
    ms = union_members(U)
    (isempty(ms) || length(ms) >= 127) && return false
    union_has_boxed(U) || return true
    return union_payload_size(U) > 0 || union_nroots(U) > 0
end

"Whether every member of the union `U` is pointer-free: it is then stored inline."
function is_bits_union(@nospecialize U)
    U isa Union || return false
    ms = Base.uniontypes(U)
    return length(ms) < 127 && all(M -> union_member_ok(M; bits=true), ms)
end

# a member that is only references lives in the roots alone, not in the payload
allpointers(@nospecialize M) = npointers(M) > 0 && sizeof(M) == npointers(M) * sizeof(Ptr{Cvoid})
in_payload(@nospecialize M) = repr_kind(M) !== Ghost && !allpointers(M)
member_nroots(@nospecialize M) = repr_kind(M) === Ghost ? 0 : npointers(M)

"The size of the payload of an unboxed union: its largest member with data."
union_payload_size(@nospecialize U) =
    maximum((sizeof(M) for M in union_members(U) if in_payload(M)); init=0)
"The alignment of the payload of an unboxed union."
union_payload_align(@nospecialize U) =
    maximum((Base.datatype_alignment(M) for M in union_members(U) if in_payload(M)); init=1)
"The number of references of an unboxed union: the most of any member."
union_nroots(@nospecialize U) = maximum((member_nroots(M) for M in union_members(U)); init=0)
"Whether values of an unboxed union carry a box (unions of ghosts don't need one)."
union_has_box(@nospecialize U) =
    union_has_boxed(U) || union_payload_size(U) > 0 || union_nroots(U) > 0

"""
    JuliaCodegen.union_tindex(U, M) -> Int

The type index of the member `M` in values of the unboxed union `U`.
"""
function union_tindex(@nospecialize(U), @nospecialize(M))
    i = findfirst(x -> x === M, union_members(U))
    i === nothing && unsupported(M, " is not an unboxed member of ", U)
    return i
end
