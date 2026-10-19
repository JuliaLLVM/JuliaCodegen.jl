# `ccall` (`:foreigncall`), `cglobal` and `GC.@preserve`: C signatures from the platform
# ABI (src/cabi.jl), as native `function_sig_t::generate_func_sig` builds them, and the
# references to C symbols, which are relocatable: a symbol of Julia's runtime is declared
# by name (the JIT or an image's linker binds it), any other is looked up on first use
# (`jl_load_and_lookup`) and cached in a global of the module.

## how values are passed

"""
    JuliaCodegen.ccall_kind(T, ret=false) -> Symbol

How a `ccall` argument or result of declared type `T` is passed, before the C ABI is
asked: `:void`, `:boxed` (a `jl_value_t*`, as a tracked pointer), `:ref` (`Ref{T}`: a
pointer to the data), `:scalar` (primitive types) or `:aggregate` (a struct by value).
A `Ref{T}` result means a `jl_value_t*` of type `T`.
"""
function ccall_kind(@nospecialize(T), ret::Bool=false)
    T === Cvoid && return :void
    T isa DataType && T <: Ref && !(T <: Ptr) && return ret ? :boxed : :ref
    isprimitivetype(T) && return :scalar
    ccall_boxed(T) && return :boxed
    # any other struct is passed by value, a mutable one as its contents (`_julia_struct_to_llvm`)
    if ismutabletype(T)
        ccall_mutable_byvalue(T) || unsupported("the ccall argument or result type ", T)
    else
        (isbitstype(T) && repr_kind(T) === Inline) || unsupported("the ccall argument or result type ", T)
    end
    sizeof(T) == 0 && unsupported("a ccall with the zero-size aggregate ", T)
    return :aggregate
end

# whether `T` is passed as a `jl_value_t*`: `Any`, abstract types, kinds, arrays and
# memory, and objects with an opaque layout (`String`, `Symbol`, ...)
function ccall_boxed(@nospecialize T)
    T === Any && return true
    (T isa DataType && isconcretetype(T)) || return true
    (T <: Type || T <: Array || T <: GenericMemory) && return true
    T.layout == C_NULL && return false
    l = unsafe_load(Ptr{Base.DataTypeLayout}(T.layout))
    return l.nfields == 0 && l.npointers > 0
end

# a mutable struct passed by value: its contents must be inline without references
ccall_mutable_byvalue(@nospecialize T) =
    sizeof(T) > 0 && fieldcount(T) > 0 && fieldoffset(T, 1) == 0 &&
    Base.datatype_pointerfree(T) && inline_representable(T) &&
    all(i -> field_storage(T, i) in (FieldInline, FieldGhost), 1:fieldcount(T))

# the contents of a by-value argument (loaded from the object for a mutable struct)
function ccall_value(fc::FnCtx, v::CGVal, @nospecialize T)
    ismutabletype(T) || return convert_repr(fc, v, T)
    v.kind === Boxed || unsupported("the ccall argument ", T, " from a ", v.kind, " value")
    ld = LLVM.load!(fc.builder, value_type(fc, ccall_inline_type(T)), derived(fc, v.V);
                    align=Base.datatype_alignment(T))
    return inline(T, tbaa!(fc, ld, field_tbaa(fc, T)))
end

# the inline type with the layout of a mutable struct's contents
ccall_inline_type(@nospecialize(T)) = ismutabletype(T) ? NTuple{0,Nothing} : T

# a by-value result: a mutable struct is copied into a new object
function ccall_result(fc::FnCtx, v::LLVM.Value, @nospecialize T)
    ismutabletype(T) || return inline(T, v)
    obj = emit_allocation(fc, T)
    st = LLVM.store!(fc.builder, v, derived(fc, obj); align=Base.datatype_alignment(T))
    tbaa!(fc, st, field_tbaa(fc, T))
    return boxed(T, obj)
end

## C signatures

"""
    JuliaCodegen.CSig

The C signature of a `ccall` or `cfunction` (native `function_sig_t`).
"""
struct CSig
    "The result: `:void`, `:boxed`, `:scalar`, `:aggregate` or `:sret`."
    rk::Symbol
    "The result's own C type (the pointee of an sret pointer)."
    lrt::LLVM.LLVMType
    "The signature's result type (void with sret)."
    prt::LLVM.LLVMType
    "Per argument: `:boxed`, `:ref`, `:scalar`, `:aggregate` or `:byval`."
    kinds::Vector{Symbol}
    "Each argument's own C type."
    fargt::Vector{LLVM.LLVMType}
    "The signature's parameter types, after any sret pointer."
    params::Vector{LLVM.LLVMType}
    attrs::Vector{Vector{LLVM.Attribute}}
    retattrs::Vector{LLVM.Attribute}
    "The attributes of the sret pointer."
    sretattrs::Vector{LLVM.Attribute}
end

# the LLVM type of a value passed by value (mutable structs: their contents)
function c_value_type(ls::Layouts, @nospecialize(T))
    if ismutabletype(T)
        elts = LLVM.LLVMType[layout(ls, fieldtype(T, i)).llvm for i in 1:fieldcount(T)
                             if field_storage(T, i) === FieldInline]
        return LLVM.StructType(elts)
    end
    return layout(ls, T).llvm
end

# a small integer argument is extended to 32 bits by the caller; on RISC-V every 4-byte
# one is sign-extended (as clang does for XLEN)
function c_int_ext(kind::Symbol, @nospecialize(T))
    kind === :riscv64 && sizeof(T) == 4 && return :signext
    primitive_nbits(T) < 32 && return T <: Signed ? :signext : :zeroext
    return nothing
end

"""
    JuliaCodegen.c_function_sig(ls, target, rt, rk, argtypes; nreq=0) -> CSig

The C signature of a call with the result type `rt` (passed as `rk`, see
[`ccall_kind`](@ref JuliaCodegen.ccall_kind)) and argument types `argtypes`, of which the
first `nreq` are required (the others are variadic; 0: not variadic), in the C ABI of
`target`: the result is classified first, then each argument in order.
"""
function c_function_sig(ls::Layouts, target::Target, @nospecialize(rt), rk::Symbol, argtypes;
                        nreq::Int=0)
    kind = target.c_abi
    abi = c_abi_layout(kind)
    P = T_ptr()
    retattrs = LLVM.Attribute[]
    sretattrs = LLVM.Attribute[]
    if rk === :void
        use_sret!(abi, Nothing)
        lrt = prt = LLVM.VoidType()
    elseif rk === :boxed || rt <: Ptr || rt <: Core.LLVMPtr
        use_sret!(abi, Ptr{Cvoid})          # (passed as a pointer)
        lrt = prt = rk === :boxed ? T_tracked() : primitive_llvm_type(rt)
    else
        lrt = rk === :scalar ? primitive_llvm_type(rt) : c_value_type(ls, rt)
        if use_sret!(abi, rt)
            rk = :sret
            prt = LLVM.VoidType()
            # (not on Windows: LLVM used the old MinGW ABI, which this works around)
            if !(kind in (:win64, :win32))
                push!(sretattrs, LLVM.TypeAttribute("sret", lrt))
                push!(sretattrs, LLVM.EnumAttribute("align", Base.datatype_alignment(rt)))
            end
            push!(sretattrs, LLVM.EnumAttribute("noalias"))
        else
            prt = something(preferred_llvm_type(abi, rt, true), lrt)
        end
        if kind === :riscv64 && rk === :scalar && lrt isa LLVM.IntegerType
            # RISC-V returns integers as if passed as the first argument
            ext = sizeof(rt) < 4 ? (rt <: Signed ? :signext : :zeroext) :
                  sizeof(rt) == 4 ? :signext : nothing
            ext === nothing || push!(retattrs, LLVM.EnumAttribute(String(ext)))
        end
    end
    kinds = Symbol[]
    fargt = LLVM.LLVMType[]
    params = LLVM.LLVMType[]
    attrs = Vector{LLVM.Attribute}[]
    for (i, T) in enumerate(argtypes)
        k = ccall_kind(T)
        k === :void && unsupported("the ccall argument ", i, " of type ", T)
        nreq > 0 && i == nreq + 1 && (abi.varargs = true)
        vararg = nreq > 0 && i > nreq
        ab = LLVM.Attribute[]
        if k === :boxed || k === :ref
            t = k === :boxed ? T_tracked() : P
            need_pass_by_ref!(abi, Ptr{Cvoid}, t)   # (passed as a pointer)
            pat = t
        else
            t = k === :scalar ? primitive_llvm_type(T) : c_value_type(ls, T)
            ext = k === :scalar && t isa LLVM.IntegerType ? c_int_ext(kind, T) : nothing
            byref, byvalty = need_pass_by_ref!(abi, T, t)
            if T <: Ptr || T <: Core.LLVMPtr
                pat = t
            elseif byref
                pat = P
                k = :byval
                byvalty === nothing || push!(ab, LLVM.TypeAttribute("byval", byvalty))
            else
                pat = something(preferred_llvm_type(abi, T, false), t)
            end
            if !byref && vararg
                # the C default argument promotions (which don't widen `_Float16`)
                if pat isa LLVM.IntegerType && LLVM.width(pat) < 32
                    pat = LLVM.Int32Type()
                elseif pat == LLVM.FloatType()
                    pat = LLVM.DoubleType()
                end
                ext = kind === :riscv64 && pat isa LLVM.IntegerType && LLVM.width(pat) <= 32 ?
                      :signext : nothing
            end
            ext === nothing || !(pat isa LLVM.IntegerType) || push!(ab, LLVM.EnumAttribute(String(ext)))
        end
        push!(kinds, k)
        push!(fargt, t)
        push!(params, pat)
        push!(attrs, ab)
    end
    return CSig(rk, lrt, prt, kinds, fargt, params, attrs, retattrs, sretattrs)
end

# the bits of a primitive LLVM type, vectors included (0 for aggregates and pointers)
function prim_bits(ty::LLVM.LLVMType)
    ty isa LLVM.IntegerType && return LLVM.width(ty)
    isfloat_type(ty) && return float_bits(ty)
    ty isa LLVM.FP128Type && return 128
    ty isa LLVM.VectorType && return ty.length * prim_bits(ty.element_type)
    return 0
end

# a value converted between its own C type and the ABI's type (`llvm_type_rewrite`): a
# bitcast between types of the same size, a float or integer extension or truncation,
# otherwise through memory
function c_rewrite(fc::FnCtx, v::LLVM.Value, to::LLVM.LLVMType, issigned::Bool=false)
    from = LLVM.value_type(v)
    from == to && return v
    b = fc.builder
    from isa LLVM.PointerType && to isa LLVM.PointerType && return LLVM.addrspacecast!(b, v, to)
    nf, nt = prim_bits(from), prim_bits(to)
    nf > 0 && nf == nt && return LLVM.bitcast!(b, v, to)
    if isfloat_type(from) && isfloat_type(to)
        return nt > nf ? LLVM.fpext!(b, v, to) : LLVM.fptrunc!(b, v, to)
    end
    if from isa LLVM.IntegerType && to isa LLVM.IntegerType
        nt > nf || return LLVM.trunc!(b, v, to)
        return issigned ? LLVM.sext!(b, v, to) : LLVM.zext!(b, v, to)
    end
    dl = fc.cgm.layouts.datalayout
    return stack_reinterpret(fc, v, to, max(LLVM.abi_alignment(dl, from), LLVM.abi_alignment(dl, to)))
end

## symbols

# the runtime's own libraries: native code looks up a symbol without a library there
# first (its `ijl_` alias, then the symbol defined by the library itself)
const RUNTIME_HANDLES = OncePerProcess{Vector{Ptr{Cvoid}}}() do
    hs = Ptr{Cvoid}[]
    for lib in ("libjulia-internal", "libjulia")
        h = Libdl.dlopen(lib; throw_error=false)
        h === nothing || push!(hs, h)
    end
    hs
end

# `jl_dlsym(h, sym, search_deps=0)`: `sym` only if `h`'s library itself defines it
function own_dlsym(h::Ptr{Cvoid}, sym)
    r = Ref{Ptr{Cvoid}}(C_NULL)
    ok = ccall(:jl_dlsym, Cint, (Ptr{Cvoid}, Cstring, Ref{Ptr{Cvoid}}, Cint, Cint),
               h, string(sym), r, 0, 0)
    return ok == 0 ? C_NULL : r[]
end

"""
    JuliaCodegen.runtime_symbol_name(sym) -> Union{String,Nothing}

The name to declare for the C symbol `sym` if Julia's runtime defines it (its `ijl_`
alias first, as native code does), or `nothing`.
"""
function runtime_symbol_name(sym::Symbol)
    hs = RUNTIME_HANDLES()
    isempty(hs) && return nothing
    iname = Symbol("i", sym)
    own_dlsym(hs[1], iname) != C_NULL && return String(iname)
    any(h -> own_dlsym(h, sym) != C_NULL, hs) && return String(sym)
    return nothing
end

# an external declaration: a function of type `ft`, or without `ft`, a global
function declare_symbol(cgm::CGModule, name::String, ft=nothing)
    mod = cgm.mod
    haskey(mod.functions, name) && return mod.functions[name]
    haskey(LLVM.globals(mod), name) && return LLVM.globals(mod)[name]
    ft === nothing || return LLVM.Function(mod, name, ft)
    return LLVM.GlobalVariable(mod, LLVM.Int8Type(), name)
end

# a module-owned `ptr` global, initially null
function symbol_cache!(cgm::CGModule, prefix::String)
    gv = LLVM.GlobalVariable(cgm.mod, T_ptr(), unique_name(cgm, prefix))
    LLVM.initializer!(gv, LLVM.null(T_ptr()))
    LLVM.linkage!(gv, LLVM.API.LLVMInternalLinkage)
    return gv
end

# a private constant C string
function cstring!(cgm::CGModule, s::String)
    data = LLVM.ConstantDataArray(Vector{UInt8}(codeunits(s * "\0")))
    gv = LLVM.GlobalVariable(cgm.mod, LLVM.value_type(data), unique_name(cgm, "_j_str"))
    LLVM.initializer!(gv, data)
    LLVM.constant!(gv, true)
    LLVM.linkage!(gv, LLVM.API.LLVMPrivateLinkage)
    LLVM.unnamed_addr!(gv, LLVM.API.LLVMGlobalUnnamedAddr)
    return gv
end

"""
    JuliaCodegen.emit_symbol_address(fc, sym, lib; ft, libexpr) -> LLVM.Value

The address of the C symbol `sym` of the library `lib` (`nothing`: any loaded library; a
library name, or a library object such as a `Libdl.LazyLibrary`), or of the library
`libexpr` (a global read at run time, e.g. a JLL's library path). `ft` is the function
type, for a function.
"""
function emit_symbol_address(fc::FnCtx, sym::Symbol, @nospecialize(lib); ft=nothing, libexpr=nothing)
    cgm = fc.cgm
    if lib === nothing && libexpr === nothing
        rname = runtime_symbol_name(sym)
        rname === nothing || return declare_symbol(cgm, rname, ft)
        # the library that defines it, as native code finds it (`jl_dlfind`): on Windows,
        # which has no global symbol namespace, the C runtime, kernel32, ...
        found = ccall(:jl_dlfind, Cstring, (Cstring,), String(sym))
        found == C_NULL || (lib = unsafe_string(found))
    end
    b = fc.builder
    P = T_ptr()
    W = config(fc).target.pointer_size
    dynamic = libexpr !== nothing || !(lib === nothing || lib isa Union{String,Symbol})
    cache = symbol_cache!(cgm, "ccall_" * String(sym))
    cached = LLVM.load!(b, P, cache; align=W, ordering=LLVM.API.LLVMAtomicOrderingUnordered)
    from = current_block(b)
    f = current_function(fc)
    slow = LLVM.BasicBlock(f, "dlsym")
    done = LLVM.BasicBlock(f, "ccall")
    LLVM.br!(b, nonnull(fc, cached), done, slow)
    LLVM.position!(b, LLVM.at_end(slow))
    found = if dynamic
        libv = libexpr !== nothing ? emit_box(fc, operand(fc, libexpr)) : literal_pointer(fc, lib)
        lf = declare_runtime(cgm.mod, dialect(fc), :jl_lazy_load_and_lookup)
        LLVM.call!(b, LLVM.function_type(lf), lf, LLVM.Value[libv, literal_pointer(fc, sym)])
    else
        lf = declare_runtime(cgm.mod, dialect(fc), :jl_load_and_lookup)
        libname, hnd = lib === nothing ? (LLVM.null(P), declare_symbol(cgm, "jl_RTLD_DEFAULT_handle")) :
                                         (cstring!(cgm, String(lib)), symbol_cache!(cgm, "ccalllib"))
        LLVM.call!(b, LLVM.function_type(lf), lf, LLVM.Value[libname, cstring!(cgm, String(sym)), hnd])
    end
    LLVM.store!(b, found, cache; align=W, ordering=LLVM.API.LLVMAtomicOrderingRelease)
    slow_end = current_block(b)
    LLVM.br!(b, done)
    LLVM.position!(b, LLVM.at_end(done))
    p = LLVM.phi!(b, P)
    append!(LLVM.incoming(p), [(cached, from), (found, slow_end)])
    return p
end

# The target of a `ccall`, if it is known at compile time: a symbol, or `(symbol,
# library)`, possibly behind constant globals or a `tuple` call (the name is a QuoteNode
# on Julia 1.12, a tuple expression from 1.13 on); `nothing` for a pointer value.
function static_ccall_target(fc::FnCtx, @nospecialize x)
    x isa QuoteNode && return static_ccall_target(fc, x.value)
    (x isa Symbol || x isa String) && return x
    x isa Tuple && return Tuple(static_ccall_target(fc, a) for a in x)
    if x isa GlobalRef
        c = const_global(fc.cgm.world, x.mod, x.name)
        c === nothing && return nothing
        return static_ccall_target(fc, something(c))
    end
    if x isa Core.BindingPartition
        Base.is_defined_const_binding(Base.binding_kind(x)) || return nothing
        return static_ccall_target(fc, x.restriction)
    end
    Meta.isexpr(x, :tuple) && return Tuple(static_ccall_target(fc, a) for a in x.args)
    if Meta.isexpr(x, :call)
        f = x.args[1]
        fv = f isa GlobalRef ? const_global(fc.cgm.world, f.mod, f.name) : nothing
        fv === Some(Core.tuple) && return Tuple(static_ccall_target(fc, a) for a in x.args[2:end])
        # a constant global of another module, `Base.Math.libm`
        if (fv === Some(Base.getproperty) || fv === Some(Core.getfield)) && length(x.args) == 3
            m = static_ccall_target(fc, x.args[2])
            s = x.args[3] isa QuoteNode ? x.args[3].value : nothing
            if m isa Module && s isa Symbol
                c = const_global(fc.cgm.world, m, s)
                c === nothing || return static_ccall_target(fc, something(c))
            end
        end
        return nothing
    end
    return x isa Core.SSAValue || x isa Core.Argument ? nothing : x   # e.g. a LazyLibrary
end

# the library of a `(sym, lib)` target that is a global, to read at run time
function ccall_library_expr(@nospecialize x)
    x isa QuoteNode && (x = x.value)
    lib = Meta.isexpr(x, :tuple) && length(x.args) == 2 ? x.args[2] :
          Meta.isexpr(x, :call) && length(x.args) == 3 ? x.args[3] :
          x isa Tuple && length(x) == 2 ? x[2] : return nothing
    if lib isa Core.BindingPartition
        lib = (ccall(:jl_binding_partition_owner, Any, (Any,), lib)::Core.Binding).globalref
    end
    return lib isa GlobalRef ? lib : nothing
end

## ccall

@noinline throw_ccall_arg_error(msg::Symbol, @nospecialize(T), @nospecialize(x)) =
    throw(TypeError(msg, "", T, x))
@noinline ccall_arg_check(msg::Symbol, @nospecialize(T), @nospecialize(x)) =
    (x isa T || throw_ccall_arg_error(msg, T, x); nothing)
@noinline throw_ccall_target_error(@nospecialize x) =
    throw(TypeError(Symbol("ccall: first argument not a pointer or valid constant expression"),
                    "", Ptr, x))

# a `ccall` argument checked to be of the declared type `T`, as native code does
# (`typeassert_input`); for `Ptr{Cvoid}`, any `Ptr` is accepted
function ccall_typeassert(fc::FnCtx, v::CGVal, @nospecialize(T), i::Int)
    (v.kind === Bottom || v.typ <: T) && return v
    voidp = T === Ptr{Cvoid}
    chk = voidp ? Ptr : T
    msg = Symbol("ccall argument ", i)
    margs = (const_value(fc, msg), const_value(fc, chk))
    if typeintersect(v.typ, chk) === Union{}
        emit_dynamic_call_raw(fc, const_value(fc, throw_ccall_arg_error), CGVal[margs..., v])
        return emit_unreachable!(fc)
    end
    if !(v.typ <: chk)
        c = emit_isa(fc, v, chk)
        if c === nothing
            v = convert_repr(fc, v, Any)
            emit_dynamic_call_raw(fc, const_value(fc, ccall_arg_check), CGVal[margs..., v])
        else
            emit_guard!(fc, c, throw_ccall_arg_error, margs..., v)
        end
    end
    if voidp
        # any `Ptr` has the representation of a `Ptr{Cvoid}`
        v.kind === UnionVal && return union_member(fc, v, Ptr{Cvoid})
        v.kind === Boxed && return inline(T, emit_unbox(fc, v.V, T))
        v.kind === Inline && return inline(T, v.V)
    end
    return v
end

"The references that a value keeps alive: the object, or the references in an inline value."
function gc_roots(fc::FnCtx, v::CGVal)
    v.kind === Boxed && return LLVM.Value[v.V]
    v.kind === Inline && has_references(v.typ) && return reference_values(fc, v.V, v.typ)
    v.kind === UnionVal && return LLVM.Value[union_root_values(fc, v)...,
                                            (union_has_box(v.typ) ? (union_box_value(fc, v),) : ())...]
    return LLVM.Value[]
end

"""
    JuliaCodegen.emit_foreigncall(fc, ex, typ) -> CGVal

A `ccall`: the arguments passed in the C ABI of the target, the objects of `Ref`
arguments and the GC roots of the call kept alive across it.
"""
function emit_foreigncall(fc::FnCtx, ex::Expr, @nospecialize(typ))
    b = fc.builder
    name, rt, argtypes, nreq, cconv = ex.args[1:5]
    cc = cconv isa QuoteNode ? cconv.value : cconv
    gc_safe = cc isa Tuple && length(cc) >= 3 && cc[3] === true
    cc isa Tuple && length(cc) >= 4 && cc[4] === true &&
        unsupported("a ccall with a cancellation handler")
    reset_safe = cc isa Tuple && length(cc) >= 5 && cc[5] === true
    cc = cc isa Tuple ? cc[1] : cc
    cc === :llvmcall && return emit_llvmcall_cc(fc, ex, typ)
    cc in (:ccall, :cdecl, :c) || unsupported("the calling convention ", cc)
    argtypes = collect(Any, argtypes)
    target = static_ccall_target(fc, name)
    target isa Tuple && length(target) == 1 && (target = target[1])
    callee = nothing
    if target === nothing
        # a function pointer computed at run time
        p = operand(fc, name)
        if !(p.typ <: Ptr)
            typeintersect(p.typ, Ptr) === Union{} || unsupported("a ccall target of type ", p.typ)
            emit_dynamic_call_raw(fc, const_value(fc, throw_ccall_target_error), CGVal[p])
            return emit_unreachable!(fc)
        end
        p.kind === Inline || unsupported("a ccall target of type ", p.typ)
        callee = p.V
    elseif target isa Union{Symbol,String}
        r = emit_special_ccall(fc, Symbol(target), ex, rt, argtypes)
        r === nothing || return r
    end
    libexpr = target isa Tuple && length(target) == 2 && target[2] === nothing ? ccall_library_expr(name) : nothing
    nargs = length(argtypes)
    fixed = nreq == 0 ? nargs : nreq
    sig = c_function_sig(fc.cgm.layouts, config(fc).target, rt, ccall_kind(rt, true), argtypes; nreq)
    sret = sig.rk === :sret
    ft = LLVM.FunctionType(sig.prt, sret ? LLVM.LLVMType[T_ptr(); sig.params[1:fixed]] : sig.params[1:fixed];
                           vararg=nreq != 0 && nreq < nargs)
    ops = LLVM.Value[]
    roots = LLVM.Value[]
    sret_slot = nothing
    if sret
        sret_slot = entry_alloca!(fc, sig.lrt; align=Base.datatype_alignment(rt))
        push!(ops, sret_slot)
    end
    for (i, T) in enumerate(argtypes)
        v = operand(fc, ex.args[5+i])
        k = sig.kinds[i]
        if k in (:scalar, :aggregate, :byval)
            v = ccall_typeassert(fc, v, T, i)
            v.kind === Bottom && return v
        end
        if k === :aggregate
            push!(ops, c_rewrite(fc, ccall_value(fc, v, T).V, sig.params[i]))
        elseif k === :byval
            # a pointer to a copy (with a `byval` attribute, LLVM makes the copy)
            cv = ccall_value(fc, v, T)
            slot = entry_alloca!(fc, LLVM.value_type(cv.V); align=Base.datatype_alignment(T))
            tbaa!(fc, LLVM.store!(b, cv.V, slot), :stack)
            push!(ops, slot)
        elseif k === :boxed
            push!(ops, emit_box(fc, v))
        elseif k === :ref
            if v.kind === Inline && v.typ <: Ptr
                push!(ops, v.V)
            elseif v.kind === Boxed
                # a pointer to the object's data; the object stays rooted across the call
                push!(roots, v.V)
                push!(ops, call_op!(fc, "julia.pointer_from_objref", derived(fc, v.V)))
            else
                unsupported("a ccall Ref argument of type ", v.typ)
            end
        else
            cv = convert_repr(fc, v, T)
            cv.kind === Inline || unsupported("the ccall argument ", T)
            push!(ops, c_rewrite(fc, cv.V, sig.params[i], T <: Signed))
        end
    end
    for a in ex.args[6+nargs:end]       # the GC roots of the call
        append!(roots, gc_roots(fc, operand(fc, a)))
    end
    if callee === nothing
        callee = target isa Tuple ? emit_symbol_address(fc, Symbol(target[1]), target[2]; ft, libexpr) :
                                    emit_symbol_address(fc, Symbol(target), nothing; ft)
    end
    tok = isempty(roots) ? nothing : call_op!(fc, "llvm.julia.gc_preserve_begin", roots...)
    r = if gc_safe
        # (late GC lowering emits the state transitions around a `gc-transition` call)
        ptls = current_ptls!(b, config(fc), fc.cgm.tbaa, fc.current_task)
        LLVM.call!(b, ft, callee, ops, [LLVM.OperandBundle("gc-transition", LLVM.Value[ptls])])
    else
        LLVM.call!(b, ft, callee, ops)
    end
    reset_safe && (r.metadata["julia.reset_safe"] = LLVM.MDNode(LLVM.Metadata[]))
    for a in sig.sretattrs
        push!(r.argument_attributes[1], a)
    end
    for (i, ab) in enumerate(sig.attrs), a in ab
        push!(r.argument_attributes[i + sret], a)
    end
    for a in sig.retattrs
        push!(r.return_attributes, a)
    end
    tok === nothing || call_op!(fc, "llvm.julia.gc_preserve_end", tok)
    k = sig.rk
    k === :void && return ghost(Nothing, nothing)
    rty = ismutabletype(rt) ? sig.lrt : (k === :boxed ? T_tracked() : value_type(fc, rt))
    if k === :aggregate
        return ccall_result(fc, c_rewrite(fc, r, rty), rt)
    elseif k === :scalar
        return ccall_result(fc, c_rewrite(fc, r, sig.lrt, rt <: Signed), rt)
    elseif k === :sret
        return ccall_result(fc, tbaa!(fc, LLVM.load!(b, sig.lrt, sret_slot), :stack), rt)
    end
    k === :boxed && return boxed(rt <: Ref && rt !== Any && rt !== Union{} ? rt.parameters[1] : rt, r)
    return ccall_result(fc, r, rt)
end

"""
    JuliaCodegen.emit_llvmcall_cc(fc, ex, typ) -> CGVal

`ccall("llvm.name", llvmcall, rt, argtypes, args...)`: a call of the LLVM function `name`
(an intrinsic, also one that LLVM doesn't know, which back ends and validation report),
declared with the LLVM types of `llvmcall` (tuples of `VecElement`s are vectors), as
native code calls it.
"""
function emit_llvmcall_cc(fc::FnCtx, ex::Expr, @nospecialize(typ))
    b = fc.builder
    name, rt, argtypes, nreq = ex.args[1:4]
    target = static_ccall_target(fc, name)
    target isa Tuple && length(target) == 1 && (target = target[1])
    target isa Union{Symbol,String} || unsupported("an llvmcall of a name not known at compile time")
    fname = String(target)
    # (native code compiles anything but an intrinsic to an error: "llvmcall only supports
    # intrinsic calls")
    startswith(fname, "llvm.") || unsupported("an llvmcall of the non-intrinsic ", fname)
    nargs = length(argtypes)
    (nreq == 0 || nreq == nargs) || unsupported("a variadic llvmcall")
    # (native code mangles the base name of an overloaded intrinsic, e.g. `llvm.powi`, from
    # the signature)
    intr = tryparse(LLVM.Intrinsic, fname)
    intr !== nothing && LLVM.isoverloaded(intr) && LLVM.name(intr) == fname &&
        unsupported("an llvmcall of the unmangled overloaded intrinsic ", fname)
    mod = fc.cgm.mod
    lrt = llvmcall_type(fc, rt)
    lats = LLVM.LLVMType[llvmcall_type(fc, T) for T in argtypes]
    ft = LLVM.FunctionType(lrt, lats)
    f = if haskey(LLVM.functions(mod), fname)
        g = LLVM.functions(mod)[fname]
        LLVM.function_type(g) == ft || unsupported("an llvmcall of ", fname, " with another signature")
        g
    else
        LLVM.Function(mod, fname, ft)
    end
    ops = LLVM.Value[]
    for (i, T) in enumerate(argtypes)
        v = convert_repr(fc, operand(fc, ex.args[5+i]), T)
        v.kind === Bottom && return v
        v.kind === Inline || unsupported("an llvmcall argument of type ", T)
        push!(ops, LLVM.value_type(v.V) == lats[i] ? v.V : reinterpret_value(fc, v.V, lats[i]))
    end
    r = LLVM.call!(b, ft, f, ops)
    lrt isa LLVM.VoidType && return ghost(Nothing, nothing)
    rty = value_type(fc, rt)
    return inline(rt, LLVM.value_type(r) == rty ? r : reinterpret_value(fc, r, rty))
end

# Runtime functions that native code emits inline (`emit_ccall`'s special functions):
# calling them would make their argument escape (e.g. the `Ref` of `pointer_from_objref`).
function emit_special_ccall(fc::FnCtx, name::Symbol, ex::Expr, @nospecialize(rt), argtypes)
    b = fc.builder
    nargs = length(argtypes)
    arg(i) = operand(fc, ex.args[5+i])
    W = config(fc).target.pointer_size
    if name === :jl_value_ptr && nargs == 1
        T = argtypes[1]
        if T === Any && rt <: Ptr
            # pointer_from_objref: the (untracked) address of the object
            return inline(rt, call_op!(fc, "julia.pointer_from_objref", derived(fc, emit_box(fc, arg(1)))))
        elseif T <: Ptr && rt === Any
            # unsafe_pointer_to_objref: the object must be rooted elsewhere
            p = convert_repr(fc, arg(1), T)
            p.kind === Inline || return nothing
            return boxed(Any, LLVM.addrspacecast!(b, p.V, T_tracked()))
        end
    elseif (name === :jl_string_ptr || name === :jl_symbol_name) && nargs == 1 &&
           argtypes[1] === Any && rt <: Ptr
        off = name === :jl_string_ptr ? W : 3W      # (after the length; `sizeof(jl_sym_t)`)
        p = call_op!(fc, "julia.pointer_from_objref", derived(fc, emit_box(fc, arg(1))))
        return inline(rt, LLVM.gep!(b, LLVM.Int8Type(), p, [iptr(fc, off)]))
    elseif name in (:memcpy, :memmove, :memset) && nargs == 3 && (rt === Nothing || rt <: Ptr)
        vals = [convert_repr(fc, arg(i), argtypes[i]) for i in 1:3]
        all(v -> v.kind === Inline, vals) || return nothing
        dst, x, n = (v.V for v in vals)
        (LLVM.value_type(dst) isa LLVM.PointerType && LLVM.value_type(n) == iptr_type(fc)) || return nothing
        if name === :memset
            LLVM.value_type(x) isa LLVM.IntegerType || return nothing
            x = LLVM.width(LLVM.value_type(x)) > 8 ? LLVM.trunc!(b, x, LLVM.Int8Type()) : x
            LLVM.value_type(x) == LLVM.Int8Type() || return nothing
            LLVM.memset!(b, dst, x, n, 1)
        else
            LLVM.value_type(x) isa LLVM.PointerType || return nothing
            (name === :memcpy ? LLVM.memcpy! : LLVM.memmove!)(b, dst, 1, x, 1, n)
        end
        return rt === Nothing ? ghost(Nothing, nothing) : inline(rt, dst)
    end
    return nothing
end

"""
    JuliaCodegen.emit_cglobal(fc, target, typ) -> CGVal

The address of a C global (`cglobal(target, T)`), from the target expression.
"""
function emit_cglobal(fc::FnCtx, @nospecialize(tex), @nospecialize(typ))
    target = static_ccall_target(fc, tex)
    target isa Tuple && length(target) == 1 && (target = target[1])
    p = if target isa Union{Symbol,String}
        emit_symbol_address(fc, Symbol(target), nothing)
    elseif target isa Tuple && length(target) == 2 && target[2] === nothing
        libexpr = ccall_library_expr(tex)
        libexpr === nothing && unsupported("the cglobal of ", tex)
        emit_symbol_address(fc, Symbol(target[1]), nothing; libexpr)
    elseif target isa Tuple && length(target) == 2
        emit_symbol_address(fc, Symbol(target[1]), target[2])
    else
        unsupported("the cglobal of ", tex)
    end
    return inline(typ <: Ptr ? typ : Ptr{Cvoid}, p)
end

## expression heads

function emit_expr_head!(fc::FnCtx, idx::Int, ex::Expr, @nospecialize(typ))
    head = ex.head
    if head === :foreigncall
        return emit_foreigncall(fc, ex, typ)
    elseif head === :cfunction
        return emit_cfunction(fc, ex, typ)
    elseif head === :foreignglobal        # (Julia 1.14 and later)
        return emit_cglobal(fc, ex.args[1], typ)
    elseif head === :gc_preserve_begin
        roots = LLVM.Value[]
        for a in ex.args
            append!(roots, gc_roots(fc, operand(fc, a)))
        end
        tok = call_op!(fc, "llvm.julia.gc_preserve_begin", roots...)
        fc.preserve_tokens[idx] = tok
        return nothing
    elseif head === :gc_preserve_end
        tok = get(fc.preserve_tokens, (ex.args[1]::Core.SSAValue).id, nothing)
        tok === nothing || call_op!(fc, "llvm.julia.gc_preserve_end", tok)
        return nothing
    end
    r = emit_exception_head!(fc, idx, ex, typ)
    r === missing || return r
    unsupported("the expression head ", head)
end
