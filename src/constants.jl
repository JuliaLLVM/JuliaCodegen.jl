# Compile-time constants: LLVM constants for inline values, and references to objects.
#
# An object is referenced through a global variable of the module that holds its address,
# loaded once at the top of each function that uses it, as native code does with its
# `julia.constgv` globals. The globals are declared without a value: how they get one
# (the address of the object when the code is linked into the running process, or a
# relocation in an image) is up to whoever links the module (see
# [`literal_objects`](@ref JuliaCodegen.literal_objects)). So the module embeds no
# addresses of objects.

"""
    JuliaCodegen.literal_global(cgm, x) -> LLVM.GlobalVariable

The global of `cgm` that holds the address of the object `x`.
"""
function literal_global(cgm::CGModule, @nospecialize x)
    get!(cgm.literals, x) do
        gv = LLVM.GlobalVariable(cgm.mod, T_ptr(), unique_name(cgm, "jl_global"))
        LLVM.linkage!(gv, LLVM.API.LLVMExternalLinkage)
        gv
    end
end

"""
    JuliaCodegen.literal_objects(cgm) -> Vector{Pair{String,Any}}

The objects the code of `cgm` refers to, by the name of the global that must hold each
one's address.
"""
literal_objects(cgm::CGModule) = [LLVM.name(gv) => x for (x, gv) in cgm.literals]

"""
    JuliaCodegen.literal_pointer(fc, x) -> LLVM.Value

A tracked pointer to the object `x`, loaded from its global at the top of the function.
"""
function literal_pointer(fc::FnCtx, @nospecialize x)
    get!(fc.loaded, x) do
        gv = literal_global(fc.cgm, x)
        b = fc.builder
        LLVM.position!(b, top_insertion_point(fc)) do
            p = LLVM.load!(b, T_ptr(), gv; align=config(fc).target.pointer_size)
            tbaa!(fc, p, :const)
            p.metadata[LLVM.MD_invariant_load] = LLVM.MDNode(LLVM.Metadata[])
            p.metadata[LLVM.MD_nonnull] = LLVM.MDNode(LLVM.Metadata[])
            LLVM.addrspacecast!(b, p, T_tracked())
        end
    end
end

# where loads of objects go: the start of the entry block, which dominates every use
function top_insertion_point(fc::FnCtx)
    insts = LLVM.instructions(fc.top)
    return isempty(insts) ? LLVM.at_end(fc.top) : LLVM.before(first(insts))
end

"""
    JuliaCodegen.const_value(fc, x) -> CGVal

The compile-time constant `x`, in the representation of its type: a ghost, an LLVM
constant, or a pointer to the object.
"""
function const_value(fc::FnCtx, @nospecialize x)
    T = Core.Typeof(x)
    k = repr_kind(T)
    k === Ghost && return ghost(T, x)
    if k === Inline && !has_references(T)
        return inline(T, llvm_constant(fc, x, T); constant=Some(x))
    elseif k === Inline
        return inline(T, constant_with_references(fc, x, T); constant=Some(x))
    end
    return boxed(T, literal_pointer(fc, x); constant=Some(x))
end

int_constant(ty::LLVM.IntegerType, x::Integer) = LLVM.ConstantInt(ty, x)

# the LLVM constant of the inline value `x` of type `T`, with null references
function llvm_constant(fc::FnCtx, @nospecialize(x), @nospecialize(T))
    lay = layout(fc, T)
    ty = lay.llvm
    if isprimitivetype(T)
        T === Bool && return LLVM.ConstantInt(ty, x ? 1 : 0)
        T in (Float16, Float32, Float64, Core.BFloat16) && return LLVM.ConstantFP(ty, x)
        if T <: Ptr || T <: Core.LLVMPtr
            iptr = LLVM.IntType(8 * config(fc).target.pointer_size)
            return LLVM.const_inttoptr(LLVM.ConstantInt(iptr, UInt(reinterpret(UInt, x))), ty)
        end
        U = Dict(1 => UInt8, 2 => UInt16, 4 => UInt32, 8 => UInt64, 16 => UInt128)[sizeof(T)]
        return LLVM.ConstantInt(ty, reinterpret(U, x))
    end
    elements = LLVM.Constant[]
    for i in 1:fieldcount(T)
        lay.fieldidx[i] < 0 && continue
        s = lay.storage[i]
        if s === FieldInline
            push!(elements, llvm_constant(fc, getfield(x, i), fieldtype(T, i)))
        elseif s === FieldPointer
            push!(elements, LLVM.null(T_tracked()))
        else
            unsupported("a constant of ", T, " with a field stored as ", s)
        end
    end
    lay.mode === Unwrap && return elements[1]
    lay.mode === VectorLayout && return LLVM.ConstantVector(elements)
    ty isa LLVM.ArrayType && return LLVM.ConstantArray(ty.element_type, elements)
    return LLVM.ConstantStruct(ty, elements)
end

# An inline constant with references: the constant with null references, completed
# with the objects it refers to.
function constant_with_references(fc::FnCtx, @nospecialize(x), @nospecialize(T))
    has_references(T) || return llvm_constant(fc, x, T)
    lay = layout(fc, T)
    values = Any[]
    for i in 1:fieldcount(T)
        if lay.fieldidx[i] < 0 || !isdefined(x, i)
            push!(values, nothing)
        elseif lay.storage[i] === FieldPointer
            push!(values, literal_pointer(fc, getfield(x, i)))
        elseif has_references(fieldtype(T, i))
            push!(values, constant_with_references(fc, getfield(x, i), fieldtype(T, i)))
        else
            push!(values, nothing)
        end
    end
    agg = llvm_constant(fc, x, T)
    for i in 1:fieldcount(T)
        values[i] === nothing && continue
        agg = insert_field(fc, lay, agg, values[i], lay.fieldidx[i])
    end
    return agg
end

"Insert the value `v` of the element `idx` (0-based) into the inline value `agg`."
function insert_field(fc::FnCtx, lay::Layout, agg::LLVM.Value, v::LLVM.Value, idx::Int)
    b = fc.builder
    lay.mode === Unwrap && return v
    lay.mode === VectorLayout && return LLVM.insert_element!(b, agg, v, i32(idx))
    return LLVM.insert_value!(b, agg, v, idx)
end

"The element `idx` (0-based) of the inline value `agg`."
function extract_field(fc::FnCtx, lay::Layout, agg::LLVM.Value, idx::Int)
    b = fc.builder
    lay.mode === Unwrap && return agg
    lay.mode === VectorLayout && return LLVM.extract_element!(b, agg, i32(idx))
    return LLVM.extract_value!(b, agg, idx)
end
