# Values in generated code: a Julia type, its representation, and the LLVM value
# (a reduced `jl_cgval_t` of the C++ code generator).

"""
    JuliaCodegen.CGVal

A value in generated code: its Julia type `typ` (widened), its representation `kind`
(see [`Repr`](@ref JuliaCodegen.Repr)), the LLVM value `V` (`nothing` for ghosts and
`Bottom`), the value itself when it is known at compile time (`constant`), and for
inline values that may also exist as a box (null at run time if not), that box (`vboxed`,
native `Vboxed`), which boxing the value again reuses.

Use the constructors [`ghost`](@ref JuliaCodegen.ghost), [`inline`](@ref
JuliaCodegen.inline), [`boxed`](@ref JuliaCodegen.boxed), [`unboxed_union`](@ref
JuliaCodegen.unboxed_union) and [`bottom`](@ref JuliaCodegen.bottom).
"""
struct CGVal
    typ::Any
    kind::Repr
    V::Union{Nothing,LLVM.Value}
    constant::Union{Nothing,Some{Any}}
    vboxed::Union{Nothing,LLVM.Value}
end

"The ghost value `v` of type `T`."
ghost(@nospecialize(T), @nospecialize(v)) = CGVal(T, Ghost, nothing, Some{Any}(v), nothing)

"The value of code that never returns."
bottom() = CGVal(Union{}, Bottom, nothing, nothing, nothing)

"""
    inline(T, V; constant, vboxed)

An inline value of type `T`, the LLVM value `V` of its layout.
"""
function inline(@nospecialize(T), V::LLVM.Value; constant::Union{Nothing,Some}=nothing,
                vboxed::Union{Nothing,LLVM.Value}=nothing)
    return CGVal(T, Inline, V, constant === nothing ? nothing : Some{Any}(something(constant)),
                 vboxed)
end

"""
    boxed(T, V; constant)

A boxed value of type `T`: `V` is a tracked pointer to the object.
"""
boxed(@nospecialize(T), V::LLVM.Value; constant::Union{Nothing,Some}=nothing) =
    CGVal(T, Boxed, V, constant === nothing ? nothing : Some{Any}(something(constant)), nothing)

"""
    unboxed_union(U, V)

A value of the unboxed union `U`: `V` is a value of its [`union_type`](@ref
JuliaCodegen.union_type).
"""
unboxed_union(@nospecialize(U), V::LLVM.Value) = CGVal(U, UnionVal, V, nothing, nothing)

"Whether the value is known at compile time."
isconstant(v::CGVal) = v.constant !== nothing

"The value, if it is known at compile time."
constant_value(v::CGVal) = something(v.constant)

function Base.show(io::IO, v::CGVal)
    print(io, "CGVal(", v.kind, ", ", v.typ)
    isconstant(v) && (print(io, ", constant="); show(io, constant_value(v)))
    v.V === nothing || print(io, ", ", string(LLVM.value_type(v.V)))
    print(io, ")")
end
