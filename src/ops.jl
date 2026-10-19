# The intrinsics of Julia's pre-lowering IR (`julia.*`): their declarations, as the
# running Julia's code generator declares them, so that Julia's passes recognize them.
# The tests compare every declaration with native code's.

T_ptr() = LLVM.PointerType(0)
T_tracked() = LLVM.PointerType(AddrSpace.Tracked)
T_derived() = LLVM.PointerType(AddrSpace.Derived)
T_loaded() = LLVM.PointerType(AddrSpace.Loaded)

# `nocapture`, spelled `captures(none)` from LLVM 21 on
nocapture() = LLVM.version() >= v"21" ? LLVM.EnumAttribute("captures", 0) :
                                        LLVM.EnumAttribute("nocapture")

# `allocsize(i)` (0-based argument `i`, no element count)
allocsize(i) = LLVM.EnumAttribute("allocsize", (UInt64(i) << 32) | 0xffffffff)

"""
    OpSpec(type, fn, ret, params, memory)

How an intrinsic is declared: its LLVM function type (a function of nothing, called in
the module's context), its function, return and parameter attributes, and its memory
effects (`nothing` for unrestricted).
"""
struct OpSpec
    type::Base.Callable
    fn::Vector{Any}
    ret::Vector{Any}
    params::Vector{Vector{Any}}
    memory::Union{Nothing,Base.Callable}
end
OpSpec(type; fn=[], ret=[], params=Vector{Any}[], memory=nothing) =
    OpSpec(type, fn, ret, params, memory)

VOID() = LLVM.VoidType()
const FT = LLVM.FunctionType

# the intrinsics, by name; `dialect` selects the ones that differ between versions
function op_spec(dialect::JuliaIR.Dialect, name::String)
    if name == "julia.get_pgcstack" || name == "julia.get_pgcstack_or_new"
        OpSpec(() -> FT(T_ptr(), LLVM.LLVMType[]))
    elseif name == "julia.gc_alloc_obj"
        OpSpec(() -> FT(T_tracked(), [T_ptr(), LLVM.Int64Type(), T_tracked()]);
               fn=[:nounwind, :willreturn, ("allockind", 1), allocsize(1)],
               ret=[:noalias, :nonnull],
               memory=() -> LLVM.MemoryEffects(; argmem=:read, inaccessiblemem=:readwrite))
    elseif name == "julia.call"
        OpSpec(() -> FT(T_tracked(), [T_ptr(), T_tracked()]; vararg=true); ret=[:nonnull])
    elseif name == "julia.call2"
        # like julia.call, with the second argument passed after the arguments array
        OpSpec(() -> FT(T_tracked(), [T_ptr(), T_tracked(), T_tracked()]; vararg=true);
               ret=[:nonnull])
    elseif name == "julia.typeof"
        OpSpec(() -> FT(T_tracked(), [T_tracked()]); fn=[:nounwind, :norecurse],
               ret=[:nonnull], memory=() -> LLVM.MemoryEffects(:none))
    elseif name == "julia.gc_loaded"
        OpSpec(() -> FT(T_loaded(), [T_tracked(), T_ptr()]);
               fn=[:nounwind, :speculatable, :willreturn, :nosync, :norecurse],
               ret=[:noundef, :nonnull],
               params=[[nocapture(), :noundef, :nonnull, :readnone],
                       [:noundef, :nonnull, :readnone]],
               memory=() -> LLVM.MemoryEffects(:none))
    elseif name == "julia.pointer_from_objref"
        OpSpec(() -> FT(T_ptr(), [T_derived()]);
               fn=[:nounwind, :speculatable, :willreturn, :nosync, :norecurse],
               ret=[:nonnull], memory=() -> LLVM.MemoryEffects(:none))
    elseif name == "julia.safepoint"
        OpSpec(() -> FT(VOID(), [T_ptr()]);
               memory=() -> LLVM.MemoryEffects(; argmem=:readwrite, inaccessiblemem=:readwrite))
    elseif name == "llvm.julia.gc_preserve_begin"
        OpSpec(() -> FT(LLVM.TokenType(), LLVM.LLVMType[]; vararg=true))
    elseif name == "llvm.julia.gc_preserve_end"
        OpSpec(() -> FT(VOID(), [LLVM.TokenType()]))
    elseif name == "julia.write_barrier" && dialect.barrier_flavour === :write_barrier
        OpSpec(() -> FT(VOID(), [T_tracked()]; vararg=true); fn=[:nounwind, :norecurse],
               params=[[:readonly]], memory=() -> LLVM.MemoryEffects(; inaccessiblemem=:readwrite))
    elseif startswith(name, "julia.field_write_barrier.p") && name in dialect.write_barriers
        as = parse(Int, chopprefix(name, "julia.field_write_barrier.p"))
        OpSpec(() -> FT(VOID(), [T_tracked(), LLVM.PointerType(as), T_tracked()]; vararg=true);
               fn=[:nounwind, :norecurse], params=[[:readonly], [], []],
               memory=() -> LLVM.MemoryEffects(; argmem=:read, inaccessiblemem=:readwrite))
    elseif name == "julia.except_enter" && dialect.except_enter === :task_buffer
        OpSpec(() -> FT(LLVM.StructType([LLVM.Int32Type(), T_ptr()]), [T_ptr()]);
               fn=[:returns_twice])
    else
        throw(ArgumentError("$name is not an intrinsic of $dialect"))
    end
end

to_attribute(a::LLVM.Attribute) = a
to_attribute(a::Symbol) = LLVM.EnumAttribute(a)
to_attribute((kind, value)::Tuple) = LLVM.EnumAttribute(kind, value)

"""
    JuliaCodegen.declare_op(mod::LLVM.Module, dialect::JuliaIR.Dialect, name) -> LLVM.Function

The declaration of the intrinsic `name` (e.g. `"julia.gc_alloc_obj"`) in `mod`, created
on first use as the dialect's code generator declares it.
"""
function declare_op(mod::LLVM.Module, dialect::JuliaIR.Dialect, name::AbstractString)
    name = String(name)
    haskey(mod.functions, name) && return mod.functions[name]
    spec = op_spec(dialect, name)
    f = LLVM.Function(mod, name, spec.type())
    foreach(a -> push!(f.function_attributes, to_attribute(a)), spec.fn)
    foreach(a -> push!(f.return_attributes, to_attribute(a)), spec.ret)
    for (i, attrs) in enumerate(spec.params)
        foreach(a -> push!(f.parameter_attributes[i], to_attribute(a)), attrs)
    end
    spec.memory === nothing || (f.memory_effects = spec.memory())
    return f
end

"""
    JuliaCodegen.call_op!(b::IRBuilder, mod, dialect, name, args...; name="") -> LLVM.CallInst

Call the intrinsic `name` with `args`.
"""
function call_op!(b::LLVM.IRBuilder, mod::LLVM.Module, dialect::JuliaIR.Dialect,
                  op::AbstractString, args::LLVM.Value...; name::AbstractString="")
    f = declare_op(mod, dialect, op)
    return LLVM.call!(b, f.function_type, f, collect(LLVM.Value, args), name)
end

"""
    JuliaCodegen.write_barrier!(b, mod, dialect, parent, fields, values)

The write barrier for storing the objects `values` into the fields at `fields` (pointers
into `parent`, in address space 11 or 13) of the object `parent`: the object form
(`julia.write_barrier(parent, values...)`) or the field form of the dialect, with the
pairs of field and value.
"""
function write_barrier!(b::LLVM.IRBuilder, mod::LLVM.Module, dialect::JuliaIR.Dialect,
                        parent::LLVM.Value, fields::Vector{<:LLVM.Value},
                        values::Vector{<:LLVM.Value})
    if dialect.barrier_flavour === :write_barrier
        return call_op!(b, mod, dialect, "julia.write_barrier", parent, values...)
    end
    as = LLVM.addrspace(LLVM.value_type(first(fields)))
    args = LLVM.Value[]
    for (f, v) in zip(fields, values)
        push!(args, f, v)
    end
    return call_op!(b, mod, dialect, "julia.field_write_barrier.p$as", parent, args...)
end

write_barrier!(b::LLVM.IRBuilder, mod::LLVM.Module, dialect::JuliaIR.Dialect,
               parent::LLVM.Value, field::LLVM.Value, value::LLVM.Value) =
    write_barrier!(b, mod, dialect, parent, [field], [value])
