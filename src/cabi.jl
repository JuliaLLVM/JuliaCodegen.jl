# The platform C ABI for `ccall`/`cfunction` arguments and results passed by value (the
# counterpart of Julia's src/abi_*.cpp, which native code includes into src/ccall.cpp).
#
# As in native code, an ABI object (`AbiLayout`) is created per C signature and answers,
# in order, `use_sret!` for the result and `need_pass_by_ref!` for every argument (they
# may count registers), and `preferred_llvm_type` for the LLVM type a value passed
# directly is coerced to (`nothing`: its own type). `c_function_sig` (emit.jl) builds the
# C signature from these answers as native `function_sig_t::generate_func_sig` does.
#
# Native code compiles in the ABI of the host (`DefaultAbiState`); here the ABI follows
# the target triple of the module being emitted (`c_abi_kind`), so code for other targets
# can be emitted (`Target(; triple)`). Julia's type layouts are always the
# host's, so for a 32-bit target only types whose layout is the same there are
# meaningful (the layout check against the target's data layout rejects the others).
#
#   ABI_x86_64Layout   x86-64 System V (abi_x86_64.cpp)
#   ABI_Win64Layout    x86-64 Windows (abi_win64.cpp)
#   ABI_x86Layout      i686 System V (abi_x86.cpp)
#   ABI_Win32Layout    i686 Windows (abi_win32.cpp)
#   ABI_AArch64Layout  AAPCS64, also Apple arm64 (abi_aarch64.cpp; native has no Apple variant)
#   ABI_ARMLayout      32-bit ARM EABI with VFP (abi_arm.cpp)
#   ABI_RiscvLayout    riscv64 LP64D (abi_riscv.cpp, with FLEN 8)
#   ABI_PPC64leLayout  ppc64le ELFv2 (abi_ppc64le.cpp)
#   ABI_LLVMLayout     anything else: LLVM's own lowering of the Julia types (abi_llvm.cpp)

abstract type AbiLayout end

# --- type predicates shared by the ABIs -------------------------------------------------

is_fp_scalar(@nospecialize T) = T === Float64 || T === Float32 || T === Float16 ||
    T === Core.BFloat16

# (ccall.cpp) the `VecElement` tuples lowered as LLVM vectors, and those that map to a
# native x86 SIMD register (`__m128`, `__m256`, `__m512`)
is_vector_type(@nospecialize T) = is_vector_tuple(T)
is_native_simd_type(@nospecialize T) =
    sizeof(T) in (16, 32, 64) && fieldcount(T) >= 2 && is_vector_tuple(T)

# The parts of `jl_datatype_layout_t` the ABIs look at
struct CLayout
    nfields::Int
    npointers::Int
    haspadding::Bool
    isbitsegal::Bool
    fieldsizes::Vector{Int}      # `jl_field_size`
    fieldptr::Vector{Bool}       # `jl_field_isptr`
end

function c_layout(@nospecialize T)
    (T isa DataType && T.layout != C_NULL) || return nothing
    p = Ptr{UInt8}(T.layout)
    l = unsafe_load(Ptr{Base.DataTypeLayout}(p))
    flags = l.flags
    fdt = (flags >> 1) & 0x3
    nf = Int(l.nfields)
    sizes = Vector{Int}(undef, nf)
    isptr = Vector{Bool}(undef, nf)
    base = p + sizeof(Base.DataTypeLayout)        # `jl_dt_layout_fields`
    for i in 1:nf
        w = fdt == 0 ? UInt32(unsafe_load(Ptr{UInt8}(base + 2(i - 1)))) :
            fdt == 1 ? UInt32(unsafe_load(Ptr{UInt16}(base + 4(i - 1)))) :
            fdt == 2 ? unsafe_load(Ptr{UInt32}(base + 8(i - 1))) :
            unsupported("C ABI of ", T, " with foreign field descriptors")
        isptr[i] = (w & 1) != 0
        sizes[i] = Int(w >> 1)
    end
    return CLayout(nf, Int(l.npointers), (flags & 0x1) != 0, (flags & 0x80) != 0, sizes, isptr)
end

c_nfields(@nospecialize T) = (l = c_layout(T); l === nothing ? 0 : l.nfields)
# `jl_is_structtype`
c_is_structtype(@nospecialize T) = T isa DataType && !isabstracttype(T) && !isprimitivetype(T)
# a layout without references or padding, compared bit by bit (`npointers`,
# `haspadding`, `isbitsegal`)
function c_plain_layout(@nospecialize T)
    l = c_layout(T)
    l === nothing && return false
    return l.npointers == 0 && l.isbitsegal && !l.haspadding
end

"The ABI object for a C signature of the ABI `kind` (see [`c_abi_kind`](@ref JuliaCodegen.c_abi_kind))."
function c_abi_layout(kind::Symbol)
    kind === :x86_64 && return ABI_x86_64Layout()
    kind === :win64 && return ABI_Win64Layout()
    kind === :x86 && return ABI_x86Layout()
    kind === :win32 && return ABI_Win32Layout()
    kind === :aarch64 && return ABI_AArch64Layout()
    kind === :arm && return ABI_ARMLayout()
    kind === :riscv64 && return ABI_RiscvLayout()
    kind === :ppc64le && return ABI_PPC64leLayout()
    return ABI_LLVMLayout()
end

# --- ABI_LLVMLayout (abi_llvm.cpp) ------------------------------------------------------

mutable struct ABI_LLVMLayout <: AbiLayout
    varargs::Bool
end
ABI_LLVMLayout() = ABI_LLVMLayout(false)
use_sret!(::ABI_LLVMLayout, @nospecialize(T)) = false
need_pass_by_ref!(::ABI_LLVMLayout, @nospecialize(T), ty) = (false, nothing)
preferred_llvm_type(::ABI_LLVMLayout, @nospecialize(T), isret::Bool) = nothing

# --- ABI_x86_64Layout (abi_x86_64.cpp) --------------------------------------------------
#
# Aggregates of at most 16 bytes are classified per eightbyte (INTEGER or SSE) and
# coerced to `{iN|half|float|double, ...}`; `VecElement` tuples that map to SIMD registers
# are passed as LLVM vectors; larger aggregates, one-element floating-point vectors (as
# GCC does) and inline unions are passed in memory (`byval` pointer arguments, `sret`
# results). Aggregates that no longer fit into the remaining argument registers are
# passed in memory too.

mutable struct ABI_x86_64Layout <: AbiLayout
    int_regs::Int
    sse_regs::Int
    varargs::Bool
end
ABI_x86_64Layout() = ABI_x86_64Layout(6, 8, false)

mutable struct CClassification
    memory::Bool
    classes::Vector{Symbol}      # per eightbyte: :none, :integer, :sse, :memory
end
CClassification() = CClassification(false, [:none, :none])

function cmerge(a::Symbol, c::Symbol)
    a === c && return a
    a === :none && return c
    c === :none && return a
    (a === :memory || c === :memory) && return :memory
    (a === :integer || c === :integer) && return :integer
    return :sse
end

function add_field!(cl::CClassification, off::Int, c::Symbol)
    cl.memory && return
    idx = off < 8 ? 1 : 2
    nw = cmerge(cl.classes[idx], c)
    if nw !== cl.classes[idx]
        cl.classes[idx] = nw
        if nw === :memory
            cl.classes[3-idx] = :memory
            cl.memory = true
        end
    end
end

function classify_type!(cl::CClassification, @nospecialize(T), off::Int)
    if is_fp_scalar(T)
        add_field!(cl, off, :sse)
    elseif T isa DataType && T <: Ptr
        add_field!(cl, off, :integer)
    elseif sizeof(T) == 0
    elseif isprimitivetype(T)
        if sizeof(T) <= 8
            add_field!(cl, off, :integer)
        elseif sizeof(T) <= 16
            add_field!(cl, off, :integer)
            add_field!(cl, off + 8, :integer)
        else
            add_field!(cl, off, :memory)
        end
    elseif is_native_simd_type(T)
        add_field!(cl, off, :sse)
    elseif is_vector_type(T) && fieldcount(T) == 1 && is_fp_scalar(fieldtype(fieldtype(T, 1), 1))
        add_field!(cl, off, :memory)     # GCC: one-element floating-point vectors
    elseif is_vector_type(T) && sizeof(T) == 8
        add_field!(cl, off, :sse)
    elseif sizeof(T) <= 16 && T isa DataType && fieldcount(T) > 0
        for i in 1:fieldcount(T)
            FT = fieldtype(T, i)
            if !Base.allocatedinline(FT)
                FT = Ptr{Cvoid}           # a reference: passed as a pointer
            elseif !(FT isa DataType)     # inline union
                add_field!(cl, off, :memory)
                continue
            end
            classify_type!(cl, FT, off + Int(fieldoffset(T, i)))
        end
    else
        add_field!(cl, off, :memory)
    end
    cl
end

c_classify(@nospecialize T) = classify_type!(CClassification(), T, 0)

function use_sret!(abi::ABI_x86_64Layout, @nospecialize(T))
    sret = c_classify(T).memory
    sret && (abi.int_regs -= 1)
    return sret
end

function need_pass_by_ref!(abi::ABI_x86_64Layout, @nospecialize(T), ty)
    cl = c_classify(T)
    cl.memory && return (true, ty)
    wi = count(==(:integer), cl.classes)
    ws = count(==(:sse), cl.classes)
    if wi <= abi.int_regs && ws <= abi.sse_regs
        abi.int_regs -= wi
        abi.sse_regs -= ws
    elseif c_is_structtype(T)
        # spill to memory even though it would ordinarily be passed in registers
        return (true, ty)
    end
    return (false, nothing)
end

function preferred_llvm_type(::ABI_x86_64Layout, @nospecialize(T), isret::Bool)
    is_native_simd_type(T) && return nothing
    sz = sizeof(T)
    (sz > 16 || sz == 0) && return nothing
    cl = c_classify(T)
    cl.memory && return nothing
    nbits = 8 * sz
    c1, c2 = cl.classes
    t1 = if c1 === :integer
        sz >= 8 ? LLVM.Int64Type() : LLVM.IntType(nbits)
    elseif c1 === :sse
        sz <= 2 ? LLVM.HalfType() : sz <= 4 ? LLVM.FloatType() : LLVM.DoubleType()
    else
        unsupported("C ABI classification ", cl.classes, " of ", T)
    end
    c2 === :none && return t1
    if c2 === :integer
        # keep i128 intact so register exhaustion spills the whole argument
        sz == 16 && isprimitivetype(T) && return LLVM.Int128Type()
        return LLVM.StructType(LLVM.LLVMType[t1, LLVM.IntType(nbits - 64)])
    elseif c2 === :sse
        return LLVM.StructType(LLVM.LLVMType[t1, sz <= 12 ? LLVM.FloatType() : LLVM.DoubleType()])
    end
    unsupported("C ABI classification ", cl.classes, " of ", T)
end

# --- ABI_Win64Layout (abi_win64.cpp) ----------------------------------------------------
#
# Values of 1, 2, 4 or 8 bytes are passed in a register (aggregates as an integer of their
# size), anything else by reference to a copy; only the first four arguments get the
# `byval` attribute (LLVM then makes the copy), later ones are a plain pointer to it.

mutable struct ABI_Win64Layout <: AbiLayout
    nargs::Int
    varargs::Bool
end
ABI_Win64Layout() = ABI_Win64Layout(0, false)

win64_reg_size(sz) = sz <= 2 || sz == 4 || sz == 8

function use_sret!(abi::ABI_Win64Layout, @nospecialize(T))
    (win64_reg_size(sizeof(T)) || is_native_simd_type(T)) && return false
    abi.nargs += 1
    return true
end

function need_pass_by_ref!(abi::ABI_Win64Layout, @nospecialize(T), ty)
    abi.nargs += 1
    win64_reg_size(sizeof(T)) && return (false, nothing)
    return (true, abi.nargs <= 4 ? ty : nothing)
end

function preferred_llvm_type(::ABI_Win64Layout, @nospecialize(T), isret::Bool)
    sz = sizeof(T)
    sz > 0 && win64_reg_size(sz) && !isprimitivetype(T) && return LLVM.IntType(8sz)
    return nothing
end

# --- ABI_x86Layout (abi_x86.cpp) --------------------------------------------------------
#
# i686 System V: aggregates (except `ComplexF32`/`ComplexF64`) and primitive types of more
# than 8 bytes are passed `byval` and returned through `sret`; a `ComplexF32` result is
# returned in `edx:eax` (as an `i64`).

mutable struct ABI_x86Layout <: AbiLayout
    varargs::Bool
end
ABI_x86Layout() = ABI_x86Layout(false)

is_complex_type(@nospecialize T) = T isa DataType && T.name === Complex.body.name
is_complex64(@nospecialize T) = is_complex_type(T) && T.parameters[1] === Float32
is_complex128(@nospecialize T) = is_complex_type(T) && T.parameters[1] === Float64

function use_sret!(::ABI_x86Layout, @nospecialize(T))
    sz = sizeof(T)
    sz == 0 && return false
    (is_complex64(T) || (isprimitivetype(T) && sz <= 8)) && return false
    return true
end

# an `i128` byval argument would get LLVM's 16-byte stack alignment, where C uses 4
x86_byval_type(@nospecialize(T), ty) =
    ty isa LLVM.IntegerType && LLVM.width(ty) > 64 ?
        LLVM.ArrayType(LLVM.Int32Type(), sizeof(T) ÷ 4) : ty

function need_pass_by_ref!(::ABI_x86Layout, @nospecialize(T), ty)
    (is_complex64(T) || is_complex128(T) || (isprimitivetype(T) && sizeof(T) <= 8)) &&
        return (false, nothing)
    return (true, x86_byval_type(T, ty))
end

preferred_llvm_type(::ABI_x86Layout, @nospecialize(T), isret::Bool) =
    isret && is_complex64(T) ? LLVM.Int64Type() : nothing

# --- ABI_Win32Layout (abi_win32.cpp) ----------------------------------------------------
#
# Every aggregate is passed `byval`; results of 1, 2, 4 or 8 bytes are returned in
# registers (aggregates as an integer of their size), others through `sret`.

mutable struct ABI_Win32Layout <: AbiLayout
    varargs::Bool
end
ABI_Win32Layout() = ABI_Win32Layout(false)

use_sret!(::ABI_Win32Layout, @nospecialize(T)) = !(sizeof(T) in (1, 2, 4, 8))

function need_pass_by_ref!(::ABI_Win32Layout, @nospecialize(T), ty)
    l = c_layout(T)
    (l.nfields > 0 || l.npointers > 0) && return (true, x86_byval_type(T, ty))
    # large primitive types too (avoiding i128's 16-byte stack alignment)
    isprimitivetype(T) && sizeof(T) > 8 &&
        return (true, LLVM.ArrayType(LLVM.Int32Type(), sizeof(T) ÷ 4))
    return (false, nothing)
end

function preferred_llvm_type(::ABI_Win32Layout, @nospecialize(T), isret::Bool)
    l = c_layout(T)
    (l.nfields == 0 && l.npointers == 0) && return nothing
    return LLVM.IntType(8 * sizeof(T))
end

# --- ABI_AArch64Layout (abi_aarch64.cpp) ------------------------------------------------
#
# AAPCS64: floating-point scalars and short vectors in SIMD/FP registers, homogeneous
# floating-point or short-vector aggregates of up to four members (HFA/HVA) as an array
# of their member type, other aggregates of at most 16 bytes as `[n x i64]` (or `i128`
# when 16-byte aligned), larger ones by reference to a copy (a plain pointer) and
# returned through `sret`.

mutable struct ABI_AArch64Layout <: AbiLayout
    varargs::Bool
end
ABI_AArch64Layout() = ABI_AArch64Layout(false)

# a short vector (8 or 16 bytes) is `<2 x i32>` or `<4 x i32>`
function aarch64_vectype(@nospecialize T)
    (T isa DataType && T <: Tuple) || return nothing
    l = c_layout(T)
    (l === nothing || l.nfields == 0) && return nothing
    sz = sizeof(T)
    lt = sz == 8 ? LLVM.VectorType(LLVM.Int32Type(), 2) :
         sz == 16 ? LLVM.VectorType(LLVM.Int32Type(), 4) : nothing
    lt === nothing && return nothing
    ft0 = fieldtype(T, 1)
    (ft0 isa DataType && ft0.name === VecElement.body.name) || return nothing
    ft00 = fieldtype(ft0, 1)
    (ft00 isa DataType && c_nfields(ft00) == 0) || return nothing
    all(i -> fieldtype(T, i) === ft0, 2:l.nfields) || return nothing
    return lt
end

# `jl_is_floattype` of size 2, 4, 8 or 16
function aarch64_fptype(@nospecialize T)
    (T isa DataType && T <: AbstractFloat) || return nothing
    sz = sizeof(T)
    sz == 2 ? LLVM.HalfType() : sz == 4 ? LLVM.FloatType() : sz == 8 ? LLVM.DoubleType() :
        sz == 16 ? LLVM.FP128Type() : nothing
end

function aarch64_fp_or_vectype(@nospecialize T)
    (T isa DataType && !ismutabletype(T) && c_plain_layout(T)) || return nothing
    return c_nfields(T) > 0 ? aarch64_vectype(T) : aarch64_fptype(T)
end

mutable struct HFAState
    type::Union{Nothing,LLVM.LLVMType}
    sz::Int
    nele::Int
end

function aarch64_hfa_hva!(st::HFAState, @nospecialize(T), dsz::Int)
    while (l = c_layout(T); l !== nothing && l.nfields > 0)
        vt = aarch64_vectype(T)
        if vt !== nothing
            ((st.sz != 0 && dsz != st.sz) || (st.type !== nothing && st.type != vt)) && return false
            st.type = vt
            st.sz = dsz
            st.nele += 1
            return true
        end
        is_vector_type(T) && return false
        i = findfirst(!=(0), l.fieldsizes)
        i === nothing && return false
        if l.fieldsizes[i] == dsz
            # a single non-empty field the size of the aggregate
            T = fieldtype(T, i)
            T isa DataType || return false
            continue
        end
        for j in i:l.nfields
            fsz = l.fieldsizes[j]
            fsz == 0 && continue
            FT = fieldtype(T, j)
            FT isa DataType || return false
            (st.nele > 3 || !aarch64_hfa_hva!(st, FT, fsz)) && return false
        end
        return true
    end
    st.sz != 0 && dsz != st.sz && return false
    nt = aarch64_fptype(T)
    if nt !== nothing && (st.type === nothing || st.type == nt)
        st.type = nt
        st.sz = dsz
        st.nele += 1
        return true
    end
    return false
end

# the member type and count of a homogeneous floating-point or short-vector aggregate
function aarch64_hfa_hva(@nospecialize T)
    dsz = sizeof(T)
    (dsz > 64 || !c_plain_layout(T)) && return nothing
    st = HFAState(nothing, 0, 0)
    aarch64_hfa_hva!(st, T, dsz) || return nothing
    return (st.type, st.nele)
end

function need_pass_by_ref!(::ABI_AArch64Layout, @nospecialize(T), ty)
    aarch64_hfa_hva(T) === nothing || return (false, nothing)
    return (sizeof(T) > 16, nothing)
end

# (rewrite type, its count, on the stack)
function aarch64_classify(@nospecialize T)
    aarch64_fp_or_vectype(T) === nothing || return (nothing, 0, false)
    h = aarch64_hfa_hva(T)
    h === nothing || return (h[1], h[2], false)
    sz = sizeof(T)
    sz > 16 && return (nothing, 0, true)
    !ismutabletype(T) && c_nfields(T) == 0 && sz in (1, 2, 4, 8, 16) &&
        return (nothing, 0, false)
    sz == 16 && Base.datatype_alignment(T) == 16 && return (LLVM.Int128Type(), 1, false)
    return (sz == 0 ? nothing : LLVM.Int64Type(), (sz + 7) >> 3, false)
end

use_sret!(::ABI_AArch64Layout, @nospecialize(T)) = aarch64_classify(T)[3]

function preferred_llvm_type(::ABI_AArch64Layout, @nospecialize(T), isret::Bool)
    fpt = aarch64_fp_or_vectype(T)
    fpt === nothing || return fpt
    ty, n, _ = aarch64_classify(T)
    ty === nothing && return nothing
    ty isa LLVM.IntegerType && LLVM.width(ty) == 128 && return ty
    return LLVM.ArrayType(ty, n)
end

# --- ABI_ARMLayout (abi_arm.cpp) --------------------------------------------------------
#
# 32-bit ARM EABI with VFP (native code requires `__ARM_PCS_VFP`): floating-point scalars
# and homogeneous floating-point aggregates of up to four members keep their LLVM type
# (the back end assigns VFP registers), other aggregates are coerced to an array of
# `i32`/`i64` (by alignment); results larger than 4 bytes that are not one of these go
# through `sret`. Nothing is passed by reference.

mutable struct ABI_ARMLayout <: AbiLayout
    varargs::Bool
end
ABI_ARMLayout() = ABI_ARMLayout(false)

function arm_fptype(@nospecialize T)
    (T isa DataType && !ismutabletype(T) && c_nfields(T) == 0) || return nothing
    T <: AbstractFloat || return nothing
    sz = sizeof(T)
    sz == 2 ? LLVM.HalfType() : sz == 4 ? LLVM.FloatType() : sz == 8 ? LLVM.DoubleType() : nothing
end

# the number of members of a homogeneous floating-point aggregate (0: not one), and
# their type
function arm_legal_ha(@nospecialize T)
    c_is_structtype(T) || return (0, nothing)
    (sizeof(T) > 64 || !c_plain_layout(T)) && return (0, nothing)
    base = nothing
    total = 0
    for i in 1:c_nfields(T)
        FT = fieldtype(T, i)
        FT isa DataType || return (0, nothing)
        t = arm_fptype(FT)
        if t !== nothing
            total += 1
        else
            m, t = arm_legal_ha(FT)
            m == 0 && return (0, nothing)
            total += m
        end
        if base === nothing
            base = t
        elseif base != t
            return (0, nothing)
        end
    end
    (total < 1 || total > 4) && return (0, nothing)
    return (total, base)
end

arm_cprc(@nospecialize T) = arm_fptype(T) !== nothing || arm_legal_ha(T)[1] != 0

# (in registers, on the stack, rewritten)
function arm_classify(@nospecialize(T), isret::Bool)
    arm_cprc(T) && return (true, false, false)
    isret && T === Float16 && return (true, false, false)
    isprimitivetype(T) && sizeof(T) <= 8 && return (true, false, false)
    isret || return (false, false, true)
    return sizeof(T) <= 4 ? (true, false, true) : (false, true, true)
end

use_sret!(::ABI_ARMLayout, @nospecialize(T)) = arm_classify(T, true)[2]
need_pass_by_ref!(::ABI_ARMLayout, @nospecialize(T), ty) = (false, nothing)

function preferred_llvm_type(::ABI_ARMLayout, @nospecialize(T), isret::Bool)
    fpt = arm_fptype(T)
    fpt === nothing || return fpt
    arm_classify(T, isret)[3] || return nothing
    align = clamp(Base.datatype_alignment(T), 4, 8)
    return LLVM.ArrayType(LLVM.IntType(8align), cld(sizeof(T), align))
end

# --- ABI_RiscvLayout (abi_riscv.cpp) ----------------------------------------------------
#
# riscv64 with the LP64D calling convention (native code uses the FLEN it was built for,
# 8 off the host): aggregates of one or two fields with at least one floating-point one
# use the hardware floating-point convention while FP (and integer) registers remain,
# as `float`/`double` or a `{fp, fp|int}` pair; others of at most 16 bytes are passed as
# `i64`, `[2 x i64]` or a 16-byte aligned `i128`, larger ones by reference to a copy (a
# plain pointer) and returned through `sret`. The result is classified first: an `sret`
# pointer takes an integer register. Variadic arguments never use FP registers.

mutable struct ABI_RiscvLayout <: AbiLayout
    avail_gprs::Int
    avail_fprs::Int
    ret_classified::Bool
    cached::Union{Nothing,LLVM.LLVMType}
    varargs::Bool
end
ABI_RiscvLayout() = ABI_RiscvLayout(8, 8, false, nothing, false)

const RISCV_XLEN = 8
const RISCV_FLEN = 8

riscv_is_float(@nospecialize T) =
    T === Float16 || T === Core.BFloat16 || T === Float32 || T === Float64
riscv_is_pointer(@nospecialize T) = T isa DataType && (T <: Ptr || T <: Core.LLVMPtr)

function riscv_fptype(@nospecialize T)
    T === Core.BFloat16 && return LLVM.BFloatType()
    sz = sizeof(T)
    sz == 2 ? LLVM.HalfType() : sz == 4 ? LLVM.FloatType() : sz == 8 ? LLVM.DoubleType() :
        LLVM.FP128Type()
end

riscv_inttype(@nospecialize T) = T === Bool ? LLVM.Int8Type() : LLVM.IntType(8 * sizeof(T))

# collect the (at most two) fields of an aggregate eligible for the floating-point
# convention, as (:float|:integer, type)
function riscv_fp_conv!(eles::Vector{Tuple{Symbol,Any}}, @nospecialize T)
    if isprimitivetype(T)
        if riscv_is_float(T)
            sizeof(T) > RISCV_FLEN && return false
            length(eles) >= 2 && return false
            push!(eles, (:float, T))
        else
            (sizeof(T) > RISCV_XLEN || riscv_is_pointer(T)) && return false
            isempty(eles) && (push!(eles, (:integer, T)); return true)
            eles[1][1] === :integer && return false     # two integers
            length(eles) >= 2 && return false
            push!(eles, (:integer, T))
        end
        return true
    end
    is_vector_type(T) && return false
    l = c_layout(T)
    l === nothing && return false
    for i in 1:l.nfields
        l.fieldsizes[i] == 0 && continue
        l.fieldptr[i] && return false
        FT = fieldtype(T, i)
        FT isa DataType || return false        # inline unions are not flattened
        riscv_fp_conv!(eles, FT) || return false
    end
    return true
end

# the coerced type of T (`nothing`: its own) and whether it is passed by reference,
# taking its registers from `regs` = [gprs, fprs]
function riscv_classify(@nospecialize(T), regs::Vector{Int})
    T === Nothing && return (nothing, false)
    eles = Tuple{Symbol,Any}[]
    if riscv_fp_conv!(eles, T) && !isempty(eles)
        k1, T1 = eles[1]
        k2, T2 = length(eles) >= 2 ? eles[2] : (:none, nothing)
        if k1 === :float
            if k2 === :float
                if regs[2] >= 2
                    regs[2] -= 2
                    return (LLVM.StructType(LLVM.LLVMType[riscv_fptype(T1), riscv_fptype(T2)]), false)
                end
            elseif k2 === :integer
                if regs[2] >= 1 && regs[1] >= 1
                    regs[2] -= 1
                    regs[1] -= 1
                    return (LLVM.StructType(LLVM.LLVMType[riscv_fptype(T1), riscv_inttype(T2)]), false)
                end
            elseif regs[2] >= 1
                # one floating-point field: passed as a standalone floating-point value
                regs[2] -= 1
                return (riscv_fptype(T1), false)
            end
        elseif k2 === :float
            if regs[2] >= 1 && regs[1] >= 1
                regs[2] -= 1
                regs[1] -= 1
                return (LLVM.StructType(LLVM.LLVMType[riscv_inttype(T1), riscv_fptype(T2)]), false)
            end
        end
    end
    dsz = sizeof(T)
    if dsz > 2 * RISCV_XLEN
        regs[1] >= 1 && (regs[1] -= 1)
        return (nothing, !isprimitivetype(T))   # (LLVM passes large scalars)
    end
    if dsz > RISCV_XLEN
        regs[1] = max(regs[1] - 2, 0)
        isprimitivetype(T) && return (nothing, false)
        align = Base.datatype_alignment(T)
        align > RISCV_XLEN && return (align == 16 ? LLVM.Int128Type() : LLVM.Int64Type(), false)
        return (LLVM.ArrayType(LLVM.Int64Type(), 2), false)
    end
    regs[1] >= 1 && (regs[1] -= 1)
    isprimitivetype(T) || return (LLVM.Int64Type(), false)
    riscv_is_float(T) && return (riscv_fptype(T), false)
    return (riscv_inttype(T), false)
end

function use_sret!(abi::ABI_RiscvLayout, @nospecialize(T))
    abi.ret_classified && error("use_sret! must be called once, before the arguments")
    abi.ret_classified = true
    ty, onstack = riscv_classify(T, [2, RISCV_FLEN == 0 ? 0 : 2])
    abi.cached = ty
    onstack && (abi.avail_gprs -= 1)
    return onstack
end

function need_pass_by_ref!(abi::ABI_RiscvLayout, @nospecialize(T), ty)
    abi.ret_classified || error("the result must be classified before the arguments")
    regs = [abi.avail_gprs, abi.varargs ? 0 : abi.avail_fprs]
    lt, onstack = riscv_classify(T, regs)
    abi.avail_gprs = regs[1]
    abi.varargs || (abi.avail_fprs = regs[2])
    abi.cached = lt
    return (onstack, nothing)
end

preferred_llvm_type(abi::ABI_RiscvLayout, @nospecialize(T), isret::Bool) = abi.cached

# --- ABI_PPC64leLayout (abi_ppc64le.cpp) ------------------------------------------------
#
# ELFv2: homogeneous floating-point (`Float32`/`Float64`) or vector aggregates of up to
# eight members as an array of the member type, other aggregates as an integer of their
# size (up to 8 bytes) or an array of `i64` (`i128` when more aligned); larger
# non-homogeneous aggregates are returned through `sret` (over 16 bytes) and passed
# `byval` (over 64 bytes). `Float16`/`BFloat16` are passed as `i16`.

mutable struct ABI_PPC64leLayout <: AbiLayout
    varargs::Bool
end
ABI_PPC64leLayout() = ABI_PPC64leLayout(false)

mutable struct PPCHFA
    ty0::Any            # the member type (nothing: none yet)
    hva::Bool
end

# the number of members of a homogeneous aggregate, 9 if it is not one
function ppc_is_hfa(st::PPCHFA, @nospecialize T)
    l = c_layout(T)
    (sizeof(T) > 128 || l.npointers > 0 || !l.isbitsegal || l.haspadding) && return 9
    if l.nfields == 0
        (T === Float64 || T === Float32) || return 9
        st.hva = false
        if st.ty0 === nothing
            st.ty0 = T
        elseif st.hva || sizeof(T) != sizeof(st.ty0)
            return 9
        end
        return 1
    end
    fld0 = fieldtype(T, 1)
    (fld0 isa DataType && T.name !== VecElement.body.name) || return 9
    if fld0.name === VecElement.body.name
        (isprimitivetype(fld0.parameters[1]) && sizeof(T) <= 16) || return 9
        l.nfields in (1, 2, 4, 8, 16) || return 9
        st.hva = true
        if st.ty0 === nothing
            st.ty0 = T
        elseif !st.hva || sizeof(T) != sizeof(st.ty0)
            return 9
        end
        all(i -> fieldtype(T, i) === fld0, 2:l.nfields) || return 9
        return 1
    end
    n = 0
    for i in 1:l.nfields
        FT = fieldtype(T, i)
        (FT isa DataType && c_layout(FT) !== nothing) || return 9
        n += ppc_is_hfa(st, FT)
        n > 8 && return 9
    end
    return n
end
ppc_is_hfa(@nospecialize T) = (st = PPCHFA(nothing, false); (ppc_is_hfa(st, T), st))

use_sret!(::ABI_PPC64leLayout, @nospecialize(T)) = sizeof(T) > 16 && ppc_is_hfa(T)[1] > 8

function need_pass_by_ref!(::ABI_PPC64leLayout, @nospecialize(T), ty)
    sizeof(T) > 64 && ppc_is_hfa(T)[1] > 8 && return (true, ty)
    return (false, nothing)
end

function preferred_llvm_type(::ABI_PPC64leLayout, @nospecialize(T), isret::Bool)
    (T === Float16 || T === Core.BFloat16) && return LLVM.Int16Type()
    c_nfields(T) == 0 && return nothing
    hfa, st = ppc_is_hfa(T)
    if hfa <= 8
        st.ty0 === Float32 && return LLVM.ArrayType(LLVM.FloatType(), hfa)
        st.ty0 === Float64 && return LLVM.ArrayType(LLVM.DoubleType(), hfa)
        V = st.ty0
        E = fieldtype(fieldtype(V, 1), 1)
        return LLVM.ArrayType(LLVM.VectorType(primitive_llvm_type(E), fieldcount(V)), hfa)
    end
    sz = sizeof(T)
    if sz > 8
        Base.datatype_alignment(T) <= 8 && return LLVM.ArrayType(LLVM.Int64Type(), cld(sz, 8))
        return LLVM.ArrayType(LLVM.Int128Type(), cld(sz, 16))
    end
    return LLVM.IntType(8sz)
end
