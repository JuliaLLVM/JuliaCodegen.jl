# Lowering of `Core.Intrinsics` to LLVM instructions. An emitter returns `nothing` for
# operands it doesn't handle, and the call then goes to the runtime (`jl_apply_generic`
# of the intrinsic), which also throws the errors of invalid operands.

# the LLVM value of an inline operand, with `Bool` as `i1`, as the C++ code generator's
# intrinsics operate on it
function ival(fc::FnCtx, v::CGVal)
    v.kind === Inline || return nothing
    return v.typ === Bool ? LLVM.trunc!(fc.builder, v.V, LLVM.Int1Type()) : v.V
end

ival_type(fc::FnCtx, @nospecialize(T)) = T === Bool ? LLVM.Int1Type() : value_type(fc, T)

# the inline result `r` of Julia type `T`
function iresult(fc::FnCtx, r::LLVM.Value, @nospecialize(T))
    if T === Bool && LLVM.value_type(r) == LLVM.Int1Type()
        r = LLVM.zext!(fc.builder, r, LLVM.Int8Type())
    end
    return inline(T, r)
end

const INT_BINOPS = Dict{Symbol,Function}(
    :add_int => LLVM.add!, :sub_int => LLVM.sub!, :mul_int => LLVM.mul!,
    :sdiv_int => LLVM.sdiv!, :udiv_int => LLVM.udiv!, :srem_int => LLVM.srem!,
    :urem_int => LLVM.urem!, :and_int => LLVM.and!, :or_int => LLVM.or!, :xor_int => LLVM.xor!)

const FLOAT_BINOPS = Dict{Symbol,Function}(
    :add_float => LLVM.fadd!, :sub_float => LLVM.fsub!, :mul_float => LLVM.fmul!,
    :div_float => LLVM.fdiv!, :rem_float => LLVM.frem!,
    :add_float_fast => LLVM.fadd!, :sub_float_fast => LLVM.fsub!,
    :mul_float_fast => LLVM.fmul!, :div_float_fast => LLVM.fdiv!, :rem_float_fast => LLVM.frem!)

const ICMP = Dict{Symbol,Any}(
    :eq_int => LLVM.API.LLVMIntEQ, :ne_int => LLVM.API.LLVMIntNE,
    :slt_int => LLVM.API.LLVMIntSLT, :ult_int => LLVM.API.LLVMIntULT,
    :sle_int => LLVM.API.LLVMIntSLE, :ule_int => LLVM.API.LLVMIntULE)

const FCMP = Dict{Symbol,Any}(
    :eq_float => LLVM.API.LLVMRealOEQ, :ne_float => LLVM.API.LLVMRealUNE,
    :lt_float => LLVM.API.LLVMRealOLT, :le_float => LLVM.API.LLVMRealOLE,
    :eq_float_fast => LLVM.API.LLVMRealOEQ, :ne_float_fast => LLVM.API.LLVMRealUNE,
    :lt_float_fast => LLVM.API.LLVMRealOLT, :le_float_fast => LLVM.API.LLVMRealOLE)

const CASTS = Dict{Symbol,Function}(
    :sext_int => LLVM.sext!, :zext_int => LLVM.zext!, :trunc_int => LLVM.trunc!,
    :fptoui => LLVM.fptoui!, :fptosi => LLVM.fptosi!, :uitofp => LLVM.uitofp!,
    :sitofp => LLVM.sitofp!, :fptrunc => LLVM.fptrunc!, :fpext => LLVM.fpext!)

# unary intrinsics implemented by LLVM intrinsics
const FLOAT_UNARY = Dict{Symbol,String}(
    :abs_float => "llvm.fabs", :sqrt_llvm => "llvm.sqrt", :sqrt_llvm_fast => "llvm.sqrt",
    :floor_llvm => "llvm.floor", :ceil_llvm => "llvm.ceil", :trunc_llvm => "llvm.trunc",
    :rint_llvm => "llvm.rint")

const INT_UNARY = Dict{Symbol,String}(
    :ctpop_int => "llvm.ctpop", :ctlz_int => "llvm.ctlz", :cttz_int => "llvm.cttz",
    :bswap_int => "llvm.bswap")

const CHECKED_ARITH = Dict{Symbol,String}(
    :checked_sadd_int => "llvm.sadd.with.overflow", :checked_uadd_int => "llvm.uadd.with.overflow",
    :checked_ssub_int => "llvm.ssub.with.overflow", :checked_usub_int => "llvm.usub.with.overflow",
    :checked_smul_int => "llvm.smul.with.overflow", :checked_umul_int => "llvm.umul.with.overflow")

const CHECKED_DIVREM = (:checked_sdiv_int, :checked_udiv_int, :checked_srem_int, :checked_urem_int)

isfloat_type(t::LLVM.LLVMType) =
    t isa Union{LLVM.HalfType,LLVM.BFloatType,LLVM.FloatType,LLVM.DoubleType}
float_bits(t::LLVM.LLVMType) = t isa LLVM.DoubleType ? 64 : t isa LLVM.FloatType ? 32 : 16

# Whether LLVM can perform the cast between the storage types of the operand and the
# result (`CastInst::castIsValid` in native `generic_cast`); otherwise, e.g. for
# `sext_int(Int16, ::Int16)`, the runtime's intrinsic throws.
function valid_cast(name::Symbol, src::LLVM.LLVMType, dst::LLVM.LLVMType)
    isint(t) = t isa LLVM.IntegerType
    if name === :sext_int || name === :zext_int
        return isint(src) && isint(dst) && LLVM.width(dst) > LLVM.width(src)
    elseif name === :trunc_int
        return isint(src) && isint(dst) && LLVM.width(dst) < LLVM.width(src)
    elseif name === :fptoui || name === :fptosi
        return isfloat_type(src) && isint(dst)
    elseif name === :uitofp || name === :sitofp
        return isint(src) && isfloat_type(dst)
    elseif name === :fpext
        return isfloat_type(src) && isfloat_type(dst) && float_bits(dst) > float_bits(src)
    elseif name === :fptrunc
        return isfloat_type(src) && isfloat_type(dst) && float_bits(dst) < float_bits(src)
    end
    return true
end

function call_llvm_intrinsic!(fc::FnCtx, name::String, overload::Vector{<:LLVM.LLVMType},
                              args::Vector{<:LLVM.Value})
    f = LLVM.Function(fc.cgm.mod, LLVM.Intrinsic(name), collect(LLVM.LLVMType, overload))
    return LLVM.call!(fc.builder, LLVM.function_type(f), f, collect(LLVM.Value, args))
end

"""
    JuliaCodegen.atomic_ordering(order::Symbol; load) -> Union{LLVM.API.LLVMAtomicOrdering,Nothing}

The LLVM ordering of a Julia memory order, for a load or a store; `nothing` for orders
that are not valid for it (which the runtime reports).
"""
function atomic_ordering(order::Symbol; load::Bool)
    order === :not_atomic && return LLVM.API.LLVMAtomicOrderingNotAtomic
    order === :unordered && return LLVM.API.LLVMAtomicOrderingUnordered
    order === :monotonic && return LLVM.API.LLVMAtomicOrderingMonotonic
    order === :acquire && return load ? LLVM.API.LLVMAtomicOrderingAcquire : nothing
    order === :release && return load ? nothing : LLVM.API.LLVMAtomicOrderingRelease
    order === :sequentially_consistent && return LLVM.API.LLVMAtomicOrderingSequentiallyConsistent
    return nothing
end

# primitive types of a size that LLVM's atomic loads and stores support
atomic_primitive(@nospecialize T) =
    isprimitivetype(T) && sizeof(T) in (1, 2, 4, 8) && primitive_nbits(T) == 8 * sizeof(T)

"""
    JuliaCodegen.emit_intrinsic(fc, f, args, rt) -> Union{CGVal,Nothing}

The call of the intrinsic `f` with `args`, of result type `rt`, or `nothing` if it is
left to the runtime.
"""
function emit_intrinsic(fc::FnCtx, f::Core.IntrinsicFunction, args::Vector{CGVal}, @nospecialize(rt))
    name = nameof(f)
    name === :llvmcall && return emit_llvmcall(fc, args, rt)
    name === :atomic_fence && return emit_atomic_fence(fc, args)
    (name === :atomic_pointerref || name === :atomic_pointerset) &&
        return emit_atomic_pointer(fc, name, args)
    name === :have_fma && return emit_have_fma(fc, args)
    (haskey(CASTS, name) || name === :bitcast) && return emit_cast(fc, name, args)
    any(a -> a.kind !== Inline, args) && return nothing
    # arithmetic and comparisons of operands of different types are a run-time error
    if (haskey(INT_BINOPS, name) || haskey(FLOAT_BINOPS, name) || haskey(ICMP, name) ||
        haskey(FCMP, name) || startswith(String(name), "checked_")) &&
       !all(a -> a.typ === args[1].typ, args)
        return nothing
    end
    xs = LLVM.Value[ival(fc, a) for a in args]
    b = fc.builder
    if haskey(INT_BINOPS, name)
        return iresult(fc, INT_BINOPS[name](b, xs[1], xs[2]), rt)
    elseif haskey(FLOAT_BINOPS, name)
        return iresult(fc, FLOAT_BINOPS[name](b, xs[1], xs[2]), rt)
    elseif haskey(ICMP, name)
        return iresult(fc, LLVM.icmp!(b, ICMP[name], xs[1], xs[2]), Bool)
    elseif haskey(FCMP, name)
        return iresult(fc, LLVM.fcmp!(b, FCMP[name], xs[1], xs[2]), Bool)
    elseif name === :neg_int
        return iresult(fc, LLVM.neg!(b, xs[1]), rt)
    elseif name === :not_int
        return iresult(fc, LLVM.not!(b, xs[1]), rt)
    elseif name === :neg_float || name === :neg_float_fast
        return iresult(fc, LLVM.fneg!(b, xs[1]), rt)
    elseif name === :fpiseq
        return emit_fpiseq(fc, args, xs)
    elseif name in (:shl_int, :lshr_int, :ashr_int)
        return emit_shift(fc, name, xs, rt)
    elseif name === :flipsign_int
        x, y = xs
        neg = LLVM.icmp!(b, LLVM.API.LLVMIntSLT, y, LLVM.ConstantInt(LLVM.value_type(y), 0))
        return iresult(fc, LLVM.select!(b, neg, LLVM.neg!(b, x), x), rt)
    elseif haskey(FLOAT_UNARY, name)
        return iresult(fc, call_llvm_intrinsic!(fc, FLOAT_UNARY[name], [LLVM.value_type(xs[1])], xs), rt)
    elseif name === :copysign_float
        return iresult(fc, call_llvm_intrinsic!(fc, "llvm.copysign", [LLVM.value_type(xs[1])], xs), rt)
    elseif name === :fma_float
        # native code emulates a correctly rounded fma for Float16 and BFloat16
        LLVM.value_type(xs[1]) isa Union{LLVM.HalfType,LLVM.BFloatType} && return nothing
        return iresult(fc, call_llvm_intrinsic!(fc, "llvm.fma", [LLVM.value_type(xs[1])], xs), rt)
    elseif name === :muladd_float
        return iresult(fc, call_llvm_intrinsic!(fc, "llvm.fmuladd", [LLVM.value_type(xs[1])], xs), rt)
    elseif name === :min_float || name === :max_float
        nm = name === :min_float ? "llvm.minimum" : "llvm.maximum"
        return iresult(fc, call_llvm_intrinsic!(fc, nm, [LLVM.value_type(xs[1])], xs), rt)
    elseif haskey(INT_UNARY, name)
        return emit_int_unary(fc, name, xs, rt)
    elseif haskey(CHECKED_ARITH, name)
        return emit_checked_arith(fc, name, xs, rt)
    elseif name in CHECKED_DIVREM
        return emit_checked_divrem(fc, name, xs, rt)
    elseif name === :add_ptr || name === :sub_ptr
        p, off = xs
        off = name === :sub_ptr ? LLVM.neg!(b, off) : off
        return iresult(fc, LLVM.gep!(b, LLVM.Int8Type(), p, [off]), rt)
    elseif name === :pointerref
        return emit_pointerref(fc, args, xs)
    elseif name === :pointerset
        return emit_pointerset(fc, args, xs)
    end
    return nothing
end

function emit_cast(fc::FnCtx, name::Symbol, args::Vector{CGVal})
    (length(args) == 2 && isconstant(args[1])) || return nothing
    T = constant_value(args[1])
    (T isa DataType && isprimitivetype(T) && repr_kind(T) === Inline) || return nothing
    x = ival(fc, args[2])
    x === nothing && return nothing
    b = fc.builder
    dst = ival_type(fc, T)
    if name === :bitcast
        src = LLVM.value_type(x)
        src == dst && return iresult(fc, x, T)
        if src isa LLVM.PointerType && dst isa LLVM.IntegerType
            return iresult(fc, LLVM.ptrtoint!(b, x, dst), T)
        elseif src isa LLVM.IntegerType && dst isa LLVM.PointerType
            return iresult(fc, LLVM.inttoptr!(b, x, dst), T)
        elseif src isa LLVM.PointerType && dst isa LLVM.PointerType
            return iresult(fc, LLVM.addrspacecast!(b, x, dst), T)
        end
        # Bool and UInt8 have different register types (i1 and i8)
        if src == LLVM.Int1Type()
            x = LLVM.zext!(b, x, LLVM.Int8Type())
            dst = value_type(fc, T)
        elseif dst == LLVM.Int1Type()
            return iresult(fc, LLVM.trunc!(b, x, dst), T)
        end
        # (`primitive type U4 4` is `i4` but has the size of a byte)
        if src isa LLVM.IntegerType && dst isa LLVM.IntegerType
            LLVM.width(src) == LLVM.width(dst) || return nothing
        end
        return iresult(fc, LLVM.bitcast!(b, x, dst), T)
    end
    valid_cast(name, value_type(fc, args[2].typ), value_type(fc, T)) || return nothing
    # integers to Float16/BFloat16 are rounded twice by LLVM on some targets (through
    # float); native code rounds once, in the runtime
    name in (:sitofp, :uitofp) && dst isa Union{LLVM.HalfType,LLVM.BFloatType} && return nothing
    return iresult(fc, CASTS[name](b, x, dst), T)
end

# `===` of floats: the same bits, or both NaN
function emit_fpiseq(fc::FnCtx, args::Vector{CGVal}, xs::Vector{LLVM.Value})
    b = fc.builder
    ity = LLVM.IntType(8 * sizeof(args[1].typ))
    same = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, LLVM.bitcast!(b, xs[1], ity), LLVM.bitcast!(b, xs[2], ity))
    nan1 = LLVM.fcmp!(b, LLVM.API.LLVMRealUNO, xs[1], xs[1])
    nan2 = LLVM.fcmp!(b, LLVM.API.LLVMRealUNO, xs[2], xs[2])
    return iresult(fc, LLVM.or!(b, same, LLVM.and!(b, nan1, nan2)), Bool)
end

# shifts by at least the bit width are defined in Julia: 0, or the sign for `ashr`
function emit_shift(fc::FnCtx, name::Symbol, xs::Vector{LLVM.Value}, @nospecialize(rt))
    b = fc.builder
    x, y = xs
    xt = LLVM.value_type(x)
    bits = LLVM.width(xt)
    yt = LLVM.value_type(y)
    # (an amount too narrow to hold `bits`, e.g. `i8` for `i256`, never is too big)
    toobig = LLVM.width(yt) < 32 && bits >= (1 << LLVM.width(yt)) ?
             LLVM.ConstantInt(LLVM.Int1Type(), 0) :
             LLVM.icmp!(b, LLVM.API.LLVMIntUGE, y, LLVM.ConstantInt(yt, bits))
    ys = LLVM.width(yt) > bits ? LLVM.trunc!(b, y, xt) :
         LLVM.width(yt) < bits ? LLVM.zext!(b, y, xt) : y
    r = if name === :shl_int
        LLVM.select!(b, toobig, LLVM.ConstantInt(xt, 0), LLVM.shl!(b, x, ys))
    elseif name === :lshr_int
        LLVM.select!(b, toobig, LLVM.ConstantInt(xt, 0), LLVM.lshr!(b, x, ys))
    else
        LLVM.ashr!(b, x, LLVM.select!(b, toobig, LLVM.ConstantInt(xt, bits - 1), ys))
    end
    return iresult(fc, r, rt)
end

function emit_int_unary(fc::FnCtx, name::Symbol, xs::Vector{LLVM.Value}, @nospecialize(rt))
    b = fc.builder
    x = xs[1]
    xt = LLVM.value_type(x)
    # a float operand (e.g. `bswap(::Float64)`) is operated on as an integer
    isfloat_type(xt) && (x = LLVM.bitcast!(b, x, LLVM.IntType(float_bits(xt))))
    ops = name in (:ctlz_int, :cttz_int) ? LLVM.Value[x, LLVM.ConstantInt(LLVM.Int1Type(), 0)] :
                                           LLVM.Value[x]
    r = call_llvm_intrinsic!(fc, INT_UNARY[name], [LLVM.value_type(x)], ops)
    LLVM.value_type(r) == xt || (r = LLVM.bitcast!(b, r, xt))
    return iresult(fc, r, rt)
end

# `Tuple{T,Bool}` of the result and whether it overflowed
function emit_checked_arith(fc::FnCtx, name::Symbol, xs::Vector{LLVM.Value}, @nospecialize(rt))
    repr_kind(rt) === Inline || return nothing
    b = fc.builder
    r = call_llvm_intrinsic!(fc, CHECKED_ARITH[name], [LLVM.value_type(xs[1])], xs)
    lay = layout(fc, rt)
    agg = LLVM.UndefValue(lay.llvm)
    agg = insert_field(fc, lay, agg, LLVM.extract_value!(b, r, 0), lay.fieldidx[1])
    ovf = LLVM.zext!(b, LLVM.extract_value!(b, r, 1), LLVM.Int8Type())
    agg = insert_field(fc, lay, agg, ovf, lay.fieldidx[2])
    return inline(rt, agg)
end

# division and remainder that throw `DivideError` for a zero divisor (and for
# `typemin ÷ -1`)
function emit_checked_divrem(fc::FnCtx, name::Symbol, xs::Vector{LLVM.Value}, @nospecialize(rt))
    b = fc.builder
    x, y = xs
    ty = LLVM.value_type(x)
    zero = LLVM.ConstantInt(ty, 0)
    ok = LLVM.icmp!(b, LLVM.API.LLVMIntNE, y, zero)
    isneg1 = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, y, LLVM.not!(b, zero))
    if name === :checked_sdiv_int
        tmin = LLVM.shl!(b, LLVM.ConstantInt(ty, 1), LLVM.ConstantInt(ty, LLVM.width(ty) - 1))
        ismin = LLVM.icmp!(b, LLVM.API.LLVMIntEQ, x, tmin)
        ok = LLVM.and!(b, ok, LLVM.not!(b, LLVM.and!(b, isneg1, ismin)))
    end
    emit_guard!(fc, ok, throw_divide_error)
    r = if name === :checked_sdiv_int
        LLVM.sdiv!(b, x, y)
    elseif name === :checked_udiv_int
        LLVM.udiv!(b, x, y)
    elseif name === :checked_srem_int
        # x % -1 == 0, without the overflow of typemin % -1
        LLVM.srem!(b, x, LLVM.select!(b, isneg1, LLVM.ConstantInt(ty, 1), y))
    else
        LLVM.urem!(b, x, y)
    end
    return iresult(fc, r, rt)
end

# the address of element `i` (1-based) of type `T` at `p`
function element_address(fc::FnCtx, p::LLVM.Value, i::LLVM.Value, @nospecialize(T))
    b = fc.builder
    it = LLVM.value_type(i)
    off = LLVM.mul!(b, LLVM.sub!(b, i, LLVM.ConstantInt(it, 1)),
                    LLVM.ConstantInt(it, Base.aligned_sizeof(T)))
    return LLVM.gep!(b, LLVM.Int8Type(), p, [off])
end

# pointerref(p::Ptr{T}, i, align)
function emit_pointerref(fc::FnCtx, args::Vector{CGVal}, xs::Vector{LLVM.Value})
    T = eltype(args[1].typ)
    (repr_kind(T) === Inline && isconstant(args[3])) || return nothing
    al = constant_value(args[3])
    ld = LLVM.load!(fc.builder, value_type(fc, T), element_address(fc, xs[1], xs[2], T);
                    align=al == 0 ? Base.datatype_alignment(T) : al)
    return inline(T, tbaa!(fc, ld, :data))
end

# pointerset(p::Ptr{T}, x, i, align)
function emit_pointerset(fc::FnCtx, args::Vector{CGVal}, xs::Vector{LLVM.Value})
    T = eltype(args[1].typ)
    (repr_kind(T) === Inline && args[2].typ === T && isconstant(args[4])) || return nothing
    al = constant_value(args[4])
    st = LLVM.store!(fc.builder, args[2].V, element_address(fc, xs[1], xs[3], T);
                     align=al == 0 ? Base.datatype_alignment(T) : al)
    tbaa!(fc, st, :data)
    return args[1]
end

# `atomic_fence(order[, scope])`: a fence for orders stronger than monotonic
function emit_atomic_fence(fc::FnCtx, args::Vector{CGVal})
    (length(args) in (1, 2) && all(isconstant, args)) || return nothing
    order = constant_value(args[1])
    scope = length(args) == 2 ? constant_value(args[2]) : :system
    scope in (:system, :singlethread) || return nothing
    order === :monotonic && return ghost(Nothing, nothing)
    ord = order === :acquire_release ? LLVM.API.LLVMAtomicOrderingAcquireRelease :
          order in (:acquire, :release, :sequentially_consistent) ?
              something(atomic_ordering(order; load=order !== :release)) : nothing
    ord === nothing && return nothing
    LLVM.fence!(fc.builder, ord, scope === :singlethread)
    return ghost(Nothing, nothing)
end

# atomic loads and stores of small primitive values through a pointer
function emit_atomic_pointer(fc::FnCtx, name::Symbol, args::Vector{CGVal})
    load = name === :atomic_pointerref
    n = load ? 2 : 3
    (length(args) == n && isconstant(args[n]) && args[1].typ <: Ptr && args[1].kind === Inline) ||
        return nothing
    T = eltype(args[1].typ)
    (T isa DataType && atomic_primitive(T)) || return nothing
    ord = atomic_ordering(constant_value(args[n]); load)
    (ord === nothing || ord == LLVM.API.LLVMAtomicOrderingNotAtomic) && return nothing
    b = fc.builder
    if load
        v = LLVM.load!(b, value_type(fc, T), args[1].V; ordering=ord, align=sizeof(T))
        return inline(T, tbaa!(fc, v, :data))
    end
    args[2].typ === T || return nothing
    tbaa!(fc, LLVM.store!(b, args[2].V, args[1].V; ordering=ord, align=sizeof(T)), :data)
    return args[1]
end

# resolved by Julia's CPUFeatures pass for the target (`julia.cpu.have_fma.*`)
function emit_have_fma(fc::FnCtx, args::Vector{CGVal})
    (length(args) == 1 && isconstant(args[1])) || return nothing
    T = constant_value(args[1])
    suffix = T === Float32 ? "f32" : T === Float64 ? "f64" : return nothing
    mod = fc.cgm.mod
    fname = "julia.cpu.have_fma." * suffix
    f = haskey(mod.functions, fname) ? mod.functions[fname] :
        LLVM.Function(mod, fname, LLVM.FunctionType(LLVM.Int1Type()))
    return iresult(fc, LLVM.call!(fc.builder, LLVM.function_type(f), f, LLVM.Value[]), Bool)
end

## llvmcall

# `llvmcall(ir, rt, argtypes, args...)`: `ir` is a function body (the arguments are %0,
# %1, ...) or a `(module, entry)` pair. The IR is parsed into the module being emitted,
# marked `alwaysinline`, and called.

function llvmcall_type(fc::FnCtx, @nospecialize T)
    (T === Nothing || T === Cvoid) && return LLVM.VoidType()
    repr_kind(T) === Inline || unsupported("llvmcall with the type ", T)
    ty = value_type(fc, T)
    # (llvmcall passes structs other than tuples as LLVM structs)
    if ty isa LLVM.ArrayType && !(T <: Tuple)
        return LLVM.StructType(fill(LLVM.eltype(ty), Int(length(ty))))
    end
    return ty
end

function emit_llvmcall(fc::FnCtx, args::Vector{CGVal}, @nospecialize(rt))
    length(args) >= 3 || return nothing
    if !isconstant(args[1])
        # IR that isn't known at compile time: native code compiles the call to an error
        emit_dynamic_call_raw(fc, const_value(fc, throw_error_message),
                              CGVal[const_value(fc, "error statically evaluating llvm IR argument")])
        return emit_unreachable!(fc)
    end
    all(isconstant, args[1:3]) || return nothing
    ir, RT, AT = constant_value(args[1]), constant_value(args[2]), constant_value(args[3])
    vals = args[4:end]
    ATs = AT isa DataType ? collect(Any, AT.parameters) : Any[]
    length(ATs) == length(vals) || return nothing
    lrt = llvmcall_type(fc, RT)
    lats = LLVM.LLVMType[llvmcall_type(fc, T) for T in ATs]
    cgm = fc.cgm
    if ir isa String
        name = unique_name(cgm, "jl_llvmcall")
        params = join(("$(string(t)) %$(i-1)" for (i, t) in enumerate(lats)), ", ")
        src = "define $(string(lrt)) @$name($params) alwaysinline {\n$ir\n}"
    elseif ir isa Tuple && length(ir) == 2 && ir[1] isa String && ir[2] isa String
        src, name = ir
    else
        return nothing
    end
    side = try
        parse(LLVM.Module, src)
    catch err
        unsupported("llvmcall IR that does not parse: ", sprint(showerror, err))
    end
    side.datalayout = cgm.mod.datalayout
    side.triple = cgm.mod.triple
    LLVM.link!(cgm.mod, side)
    f = cgm.mod.functions[name]
    LLVM.linkage!(f, LLVM.API.LLVMInternalLinkage)
    push!(f.function_attributes, LLVM.EnumAttribute("alwaysinline"))
    ops = LLVM.Value[]
    for (v, T, t) in zip(vals, ATs, lats)
        cv = convert_repr(fc, v, T)
        cv.kind === Inline || unsupported("an llvmcall argument of type ", T)
        push!(ops, LLVM.value_type(cv.V) == t ? cv.V : reinterpret_value(fc, cv.V, t))
    end
    r = LLVM.call!(fc.builder, LLVM.function_type(f), f, ops)
    lrt isa LLVM.VoidType && return ghost(Nothing, nothing)
    rty = value_type(fc, RT)
    return inline(RT, LLVM.value_type(r) == rty ? r : reinterpret_value(fc, r, rty))
end

"""
    JuliaCodegen.entry_alloca!(fc, ty; align) -> LLVM.Value

A stack slot of type `ty` in the entry block.
"""
function entry_alloca!(fc::FnCtx, ty::LLVM.LLVMType; align::Integer=0)
    b = fc.builder
    LLVM.position!(b, top_insertion_point(fc)) do
        a = LLVM.alloca!(b, ty)
        align > 0 && LLVM.alignment!(a, align)
        a
    end
end

# reinterpret a value as another LLVM type of the same size, through a stack slot
function reinterpret_value(fc::FnCtx, v::LLVM.Value, ty::LLVM.LLVMType)
    b = fc.builder
    dl = fc.cgm.layouts.datalayout
    size = max(LLVM.abi_size(dl, ty), LLVM.abi_size(dl, LLVM.value_type(v)), 1)
    slot = entry_alloca!(fc, LLVM.ArrayType(LLVM.Int8Type(), size); align=16)
    LLVM.store!(b, v, slot)
    return LLVM.load!(b, ty, slot)
end
