
# The C ABI on every target (src/cabi.jl): for a table of `ccall`/`cfunction` signatures,
# the C function signature JuliaCodegen emits for each target triple (on this host, with
# `test_module_ir(...; triple)`) — parameter and result types and their ABI attributes
# (byval, sret, signext, zeroext, align, noalias) — checked against
#  * a table of the expected declarations per target (test/cabi_targets.txt),
#    which is what Julia's native abi_*.cpp produce for these types, and
#  * clang's declaration of the equivalent C function for the same triple, with
#    JULIACODEGEN_CLANG=1 and clang installed, up to the coercion-type differences listed in `CLANG_EQUIV` and
#    `CLANG_KNOWN` (native Julia's own deviations, ported as they are).
# Native Julia selects its ABI when it is built (`DefaultAbiState` in ccall.cpp), so it
# cannot emit for another target; clang is the reference native's ABI files follow.
# Set JULIACODEGEN_CABI_REGEN=1 to rewrite the expected tables from the current output.

module CABICases
struct S1; a::Int8; end
struct S2; a::Int16; end
struct S3; a::Int8; b::Int8; c::Int8; end
struct S4; a::Int32; end
struct S5; a::Int8; b::Int8; c::Int8; d::Int8; e::Int8; end
struct S6; a::Int16; b::Int16; c::Int16; end
struct S8; a::Int32; b::Int32; end
struct S12; a::Int32; b::Int32; c::Int32; end
struct S16; a::Int64; b::Int64; end
struct S24; a::Int64; b::Int64; c::Int64; end
struct S32; a::NTuple{8,Int32}; end
struct S64; a::NTuple{8,Int64}; end
struct S72; a::NTuple{9,Int64}; end
struct SIF; i::Int32; f::Float32; end
struct SFI; f::Float32; i::Int32; end
struct SF; a::Float32; end
struct SFF; a::Float32; b::Float32; end
struct SFFF; a::Float32; b::Float32; c::Float32; end
struct SFFFF; a::Float32; b::Float32; c::Float32; d::Float32; end
struct SFFFFF; a::Float32; b::Float32; c::Float32; d::Float32; e::Float32; end
struct SD; a::Float64; end
struct SDD; a::Float64; b::Float64; end
struct SDDD; a::Float64; b::Float64; c::Float64; end
struct SDDDD; a::Float64; b::Float64; c::Float64; d::Float64; end
struct SCD; c::Int8; d::Float64; end
struct SDL; d::Float64; l::Int64; end
struct SLD; l::Int64; d::Float64; end
struct SBC; b::Bool; c::Char; end
struct SFFn; x::SFF; y::SFF; end          # nested: an HFA of four floats
struct SISF; i::Int32; s::SF; end         # nested mixed
struct SDsD; a::SD; b::Float64; end       # nested HFA of two doubles
struct SHF; a::Float16; b::Float16; end
struct SV4V4; a::NTuple{4,VecElement{Float32}}; b::NTuple{4,VecElement{Float32}}; end
end
using .CABICases: S1, S2, S3, S4, S5, S6, S8, S12, S16, S24, S32, S64, S72, SIF, SFI, SF,
    SFF, SFFF, SFFFF, SFFFFF, SD, SDD, SDDD, SDDDD, SCD, SDL, SLD, SBC, SFFn, SISF, SDsD,
    SHF, SV4V4

const V2f = NTuple{2,VecElement{Float32}}
const V4f = NTuple{4,VecElement{Float32}}
const V2d = NTuple{2,VecElement{Float64}}
const V4d = NTuple{4,VecElement{Float64}}
const V1d = NTuple{1,VecElement{Float64}}
const V2i = NTuple{2,VecElement{Int32}}

# Julia type => C type (and the C typedef it needs)
const CTYPES = Dict{Any,String}(
    Cvoid => "void", Int8 => "signed char", UInt8 => "unsigned char", Int16 => "short",
    UInt16 => "unsigned short", Int32 => "int", UInt32 => "unsigned", Int64 => "long long",
    UInt64 => "unsigned long long", Float32 => "float", Float64 => "double",
    Bool => "_Bool", Char => "unsigned", Ptr{Cvoid} => "void*", Float16 => "_Float16",
    Int128 => "__int128", ComplexF32 => "float _Complex", ComplexF64 => "double _Complex",
    V2f => "V2f", V4f => "V4f", V2d => "V2d", V4d => "V4d", V1d => "V1d", V2i => "V2i")
const CTYPEDEFS = """
typedef float V2f __attribute__((vector_size(8)));
typedef float V4f __attribute__((vector_size(16)));
typedef double V2d __attribute__((vector_size(16)));
typedef double V4d __attribute__((vector_size(32)));
typedef double V1d __attribute__((vector_size(8)));
typedef int V2i __attribute__((vector_size(8)));
typedef struct { signed char a; } S1;
typedef struct { short a; } S2;
typedef struct { signed char a, b, c; } S3;
typedef struct { int a; } S4;
typedef struct { signed char a, b, c, d, e; } S5;
typedef struct { short a, b, c; } S6;
typedef struct { int a, b; } S8;
typedef struct { int a, b, c; } S12;
typedef struct { long long a, b; } S16;
typedef struct { long long a, b, c; } S24;
typedef struct { int a[8]; } S32;
typedef struct { long long a[8]; } S64;
typedef struct { long long a[9]; } S72;
typedef struct { int i; float f; } SIF;
typedef struct { float f; int i; } SFI;
typedef struct { float a; } SF;
typedef struct { float a, b; } SFF;
typedef struct { float a, b, c; } SFFF;
typedef struct { float a, b, c, d; } SFFFF;
typedef struct { float a, b, c, d, e; } SFFFFF;
typedef struct { double a; } SD;
typedef struct { double a, b; } SDD;
typedef struct { double a, b, c; } SDDD;
typedef struct { double a, b, c, d; } SDDDD;
typedef struct { signed char c; double d; } SCD;
typedef struct { double d; long long l; } SDL;
typedef struct { long long l; double d; } SLD;
typedef struct { _Bool b; unsigned c; } SBC;
typedef struct { SFF x, y; } SFFn;
typedef struct { int i; SF s; } SISF;
typedef struct { SD a; double b; } SDsD;
#ifdef __FLT16_MAX__
typedef struct { _Float16 a, b; } SHF;
#endif
typedef struct { V4f a, b; } SV4V4;
"""
for T in (S1, S2, S3, S4, S5, S6, S8, S12, S16, S24, S32, S64, S72, SIF, SFI, SF, SFF, SFFF,
          SFFFF, SFFFFF, SD, SDD, SDDD, SDDDD, SCD, SDL, SLD, SBC, SFFn, SISF, SDsD, SHF, SV4V4)
    CTYPES[T] = string(nameof(T))
end

# the signatures: (name, result, arguments, number of fixed arguments for a variadic one)
const SCALARS = (Int8, UInt8, Int16, UInt16, Int32, UInt32, Int64, UInt64, Float32,
                 Float64, Bool, Char, Ptr{Cvoid}, Float16, Int128)
const AGGREGATES = (S1, S2, S3, S4, S5, S6, S8, S12, S16, S24, S32, S64, S72, SIF, SFI, SF,
                    SFF, SFFF, SFFFF, SFFFFF, SD, SDD, SDDD, SDDDD, SCD, SDL, SLD, SBC, SFFn,
                    SISF, SDsD, SHF, ComplexF32, ComplexF64, V2f, V4f, V2d, V4d, V1d, V2i,
                    SV4V4)
const CASES = Tuple{String,Any,Vector{Any},Int}[]
for T in (SCALARS..., AGGREGATES...)
    n = T isa DataType && T <: Tuple ? CTYPES[T] : T === Ptr{Cvoid} ? "Ptr" :
        T === ComplexF32 ? "ComplexF32" : T === ComplexF64 ? "ComplexF64" : string(nameof(T))
    # as argument (after an int, so that it is not the first) and as result
    push!(CASES, ("arg_" * n, Cvoid, Any[Int32, T], 0))
    push!(CASES, ("ret_" * n, T, Any[], 0))
end
# register exhaustion, and Windows' four `byval` arguments
push!(CASES, ("many_SDD", Cvoid, Any[Int64, Int64, Int64, Int64, Int64, SDD, SDD, SDD, SDD, SDD], 0))
push!(CASES, ("many_SIF", Float64, Any[Int64, Int64, Int64, Int64, Int64, Int64, SIF, Float64], 0))
push!(CASES, ("many_SFF", Cvoid, Any[Float64, Float64, Float64, Float64, Float64, Float64, Float64, SFF, SFF], 0))
push!(CASES, ("many_S24", S24, Any[S24, S24, S24, S24, S24, S24], 0))
push!(CASES, ("many_S16", Cvoid, Any[S16, S16, S16, S16, S16, S16], 0))
push!(CASES, ("mixed", SDDD, Any[Int8, SFF, UInt16, SDDD, Float32, S3, Bool], 0))
# variadic arguments (default promotions)
push!(CASES, ("va_ints", Int32, Any[Ptr{Cvoid}, Int8, UInt16, Bool, Int32, Int64], 1))
push!(CASES, ("va_fp", Int32, Any[Ptr{Cvoid}, Float32, Float64], 1))
push!(CASES, ("va_struct", Int32, Any[Ptr{Cvoid}, SFF, S16, SDDD], 1))

# the targets: (name, triple, cases to skip — Julia's layout of the type differs there)
const EIGHT_ALIGNED = Set{Any}([S16, S24, S64, S72, SD, SDD, SDDD, SDDDD, SCD, SDL, SLD,
                                SDsD, ComplexF64, V2d, V4d, V1d, Int64, UInt64, Float64,
                                SV4V4, V4f])
# 32-bit targets have no `__int128`
const TARGETS = [
    ("x86_64", "x86_64-unknown-linux-gnu", Set{Any}()),
    ("win64", "x86_64-pc-windows-msvc", Set{Any}()),
    ("i686", "i686-unknown-linux-gnu", union(EIGHT_ALIGNED, Set{Any}([Int128]))),
    ("win32", "i686-pc-windows-msvc", Set{Any}([Int128, V4d, SV4V4])),
    ("aarch64", "aarch64-unknown-linux-gnu", Set{Any}()),
    ("apple-arm64", "arm64-apple-darwin", Set{Any}()),
    ("armv7", "armv7l-unknown-linux-gnueabihf", Set{Any}([Int128])),
    ("riscv64", "riscv64-unknown-linux-gnu", Set{Any}()),
    ("ppc64le", "powerpc64le-unknown-linux-gnu", Set{Any}([Float16, SHF])),   # (no _Float16)
    ("llvm", "wasm32-unknown-unknown", Set{Any}([Int128, Float16, SHF])),
]

skip_case(case, skip) = any(T -> T in skip, (case[2], case[3]...))

# define `cabi_<name>(p, args...)`, a ccall of the pointer p, and `cabi_<name>_cf()`, a
# cfunction of the same signature
for (name, rt, args, nreq) in CASES
    f = Symbol(:cabi_, name)
    xs = [Symbol(:x, i) for i in eachindex(args)]
    if nreq == 0
        @eval $f(p::Ptr{Cvoid}, $(xs...)) = ccall(p, $rt, ($(args...),), $(xs...))
    else
        # `@ccall $p(fixed...; varargs...)::rt`
        fixed = [:($x::$T) for (x, T) in zip(xs[1:nreq], args[1:nreq])]
        va = [:($x::$T) for (x, T) in zip(xs[nreq+1:end], args[nreq+1:end])]
        call = Expr(:(::), Expr(:call, Expr(:$, :p), Expr(:parameters, va...), fixed...), rt)
        @eval $f(p::Ptr{Cvoid}, $(xs...)) = $(Expr(:macrocall, Symbol("@ccall"), LineNumberNode(@__LINE__, @__FILE__), call))
    end
    if nreq == 0
        cb = Symbol(f, :_cb)
        @eval @noinline $cb($(xs...)) = $(rt === Cvoid ? nothing : :(unsafe_load(Ptr{$rt}(C_NULL))))
        @eval $(Symbol(f, :_cf))() = @cfunction($cb, $rt, ($(args...),))
    end
end

# --- the C signatures JuliaCodegen emits ------------------------------------------------------

# A declaration of function type `ft` with the given attributes, as LLVM prints it
# (without the name): `<ret attrs> <ret type> (<param attrs> <param type>, ...)`
function decl_string(mod, ft, retattrs, paramattrs)
    f = LLVM.Function(mod, "csig", ft)
    try
        for a in retattrs
            push!(f.return_attributes, a)
        end
        for (i, as) in enumerate(paramattrs), a in as
            push!(f.parameter_attributes[i], a)
        end
        l = first(filter(startswith("declare"), split(string(f), '\n')))
        return normalize_decl(l)
    finally
        LLVM.erase!(f)
    end
end

# `declare [attrs] T @name(...) [#n]` => `[attrs] T (...)`, without parameter names
function normalize_decl(l::AbstractString)
    for r in (r"^declare\s+" => "", r"^define\s+(internal\s+)?" => "", r"\s*#\d+" => "",
              r"\s*\{\s*$" => "", r"@[\w.\"$]+\(" => "(", r" %\d+(?=[,)])" => "",
              r"\b(dso_local|local_unnamed_addr|arm_aapcs_vfpcc|arm_aapcscc)\s+" => "")
        l = replace(l, r)
    end
    return strip(l)
end

# The C signatures of `case` for `triple`: (ccall's call site, cfunction's wrapper), as
# declarations; for a variadic call, followed by ` va(<the variadic operands>)`. The
# message for an unsupported one; the cfunction is `nothing` for a variadic case.
function codegen_sigs(case, triple)
    name, rt, args, nreq = case
    f = getfield(@__MODULE__, Symbol(:cabi_, name))
    ccall_sig = try
        ir = test_module_ir(f, (Ptr{Cvoid}, args...); triple)
        @dispose ctx=LLVM.Context() begin
            mod = parse(LLVM.Module, ir)
            sigs = String[]
            for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
                inst isa LLVM.CallInst || continue
                LLVM.called_operand(inst) isa LLVM.Function && continue
                ft = LLVM.called_type(inst)
                n = length(LLVM.parameters(ft))
                d = decl_string(mod, ft, collect(inst.return_attributes),
                                [collect(inst.argument_attributes[i]) for i in 1:n])
                LLVM.isvararg(ft) && (d *= " va(" * join(vararg_operands(string(inst), n), ", ") * ")")
                push!(sigs, d)
            end
            length(sigs) == 1 || error("expected one C call in ", name, ", found ", sigs)
            sigs[1]
        end
    catch e
        e isa JuliaCodegen.Unsupported || rethrow()
        "unsupported: " * sprint(showerror, e)
    end
    cf = Symbol(:cabi_, name, :_cf)
    cfunction_sig = if isdefined(@__MODULE__, cf)
        try
            ir = test_module_ir(getfield(@__MODULE__, cf), (); triple)
            l = first(filter(l -> startswith(l, "define internal") && occursin("@jlcapi", l),
                             split(ir, '\n')))
            normalize_decl(l)
        catch e
            e isa JuliaCodegen.Unsupported || rethrow()
            "unsupported: " * sprint(showerror, e)
        end
    else
        nothing
    end
    return ccall_sig, cfunction_sig
end

# the variadic operands of a call instruction (as text), after `nfixed` fixed ones, as
# `<type> <attributes>`
function vararg_operands(call::AbstractString, nfixed::Int)
    call = replace(call, r",\s*!.*$" => "", r"\s*#\d+\s*$" => "")
    # the operand list: the trailing parenthesized group
    depth = 0
    j = lastindex(call)
    i = j
    for k in reverse(collect(eachindex(call)))
        c = call[k]
        c == ')' && (depth += 1)
        c == '(' && (depth -= 1)
        depth == 0 && (i = k; break)
    end
    ops = split_top(call[nextind(call, i):prevind(call, j)])[nfixed+1:end]
    return [strip(replace(o, r"\s+\S+$" => "")) for o in ops]
end

# --- clang's -------------------------------------------------------------------------------

# (opt-in, `JULIACODEGEN_CLANG=1`: clang versions differ in the IR they emit)
const CLANG = get(ENV, "JULIACODEGEN_CLANG", "") == "1" ? Sys.which("clang") : nothing

# clang's declarations of the cases for `triple` (named struct types replaced by their
# bodies), and for variadic ones its call with arguments of the case's types
function clang_decls(cases, triple)
    dir = mktempdir()
    src = joinpath(dir, "sigs.c")
    open(src, "w") do io
        println(io, CTYPEDEFS)
        for (name, rt, args, nreq) in cases
            ps = [CTYPES[T] for T in (nreq == 0 ? args : args[1:nreq])]
            nreq == 0 && isempty(ps) && push!(ps, "void")
            nreq == 0 || push!(ps, "...")
            println(io, CTYPES[rt], " ", name, "(", join(ps, ", "), ");")
            if nreq > 0
                for (i, T) in enumerate(args)
                    println(io, CTYPES[T], " g_", name, "_", i, ";")
                end
                println(io, "void call_", name, "(void) { ", name, "(",
                        join(["g_$(name)_$i" for i in eachindex(args)], ", "), "); }")
            end
        end
        println(io, "void *uses[] = {", join([c[1] for c in cases], ", "), "};")
    end
    ll = read(`$CLANG -target $triple -S -emit-llvm -O0 -w -o - $src`, String)
    lines = split(ll, '\n')
    structs = Dict{String,String}()
    for l in lines
        m = match(r"^(%[\w.]+) = type (.*)$", l)
        m === nothing || (structs[m.captures[1]] = m.captures[2])
    end
    function expand(d)
        while (m = match(r"%(struct|union)\.\w+", d)) !== nothing
            d = replace(d, Regex(replace(m.match, "." => "\\.") * "(?![\\w.])") => structs[m.match])
        end
        return d
    end
    decls = Dict{String,String}()
    for l in lines
        m = match(r"^declare .*@(\w+)\(", l)
        m === nothing && continue
        decls[m.captures[1]] = expand(normalize_decl(l))
    end
    for l in lines
        m = match(r"call .*\((.*)\) @(\w+)\(", l)
        (m === nothing || !haskey(decls, m.captures[2])) && continue
        nfixed = length(filter(!=("..."), split_top(m.captures[1])))
        va = [expand(o) for o in vararg_operands(l, nfixed)]
        decls[m.captures[2]] *= " va(" * join(va, ", ") * ")"
    end
    return decls
end

# --- comparing with clang ------------------------------------------------------------------
#
# Clang's coercion types are not always the ones native Julia picks, while LLVM lowers
# many of them identically. Both declarations are canonicalized: attributes that do not
# affect where a value is passed are dropped (`noundef`, `dead_on_unwind writable` and
# `noalias` on sret pointers, `alignstack`, the pointee types of byval/sret and alignment of
# byval and indirect pointers), first-class aggregates are flattened into their scalar
# members (a back end assigns struct and array members to registers one by one; clang
# passes them as separate arguments), and the target-specific equivalences of
# `CLANG_EQUIV` applied. Integer extension attributes are compared separately: JuliaCodegen
# must extend every argument clang extends (native code also extends where clang does not,
# e.g. on Windows and Linux AArch64, which is harmless), and the cfunction wrapper must
# extend a result where clang does (a ccall result need not be: the callee extends).

# split at top-level commas
function split_top(s::AbstractString)
    parts = String[]
    depth = 0
    start = 1
    for (i, c) in pairs(s)
        if c in "{[<("
            depth += 1
        elseif c in "}]>)"
            depth -= 1
        elseif c == ',' && depth == 0
            push!(parts, strip(s[start:prevind(s, i)]))
            start = nextind(s, i)
        end
    end
    rest = strip(s[start:end])
    isempty(rest) || push!(parts, rest)
    return parts
end

# a leading LLVM type and the rest of the string
function split_type(s::AbstractString)
    s = strip(s)
    c = s[1]
    if c in "{[<"
        close = Dict('{' => '}', '[' => ']', '<' => '>')[c]
        depth = 0
        for (i, d) in pairs(s)
            d == c && (depth += 1)
            d == close && (depth -= 1)
            depth == 0 && return s[1:i], strip(s[nextind(s, i):end])
        end
        error("unbalanced type ", s)
    end
    m = match(r"^(\S+)\s*(.*)$", s)
    return m.captures[1], m.captures[2]
end

# the scalar members of a type
function flatten_type(t::AbstractString)
    t = strip(t)
    if startswith(t, "{")
        return reduce(vcat, [flatten_type(e) for e in split_top(t[2:end-1])]; init=String[])
    elseif startswith(t, "[")
        m = match(r"^\[(\d+) x (.*)\]$", t)
        return repeat(flatten_type(m.captures[2]), parse(Int, m.captures[1]))
    end
    return [t]
end

const EXT_ATTRS = ("signext", "zeroext")

# The canonical form of a declaration: the result's and the parameters' flattened
# (type, attributes) lists, the variadic operands', and the extension attributes of the
# result and of each parameter.
function canonical_sig(d::AbstractString, target::String)
    opts = CLANG_EQUIV[target]
    equiv = opts.types
    for r in (r"\b(noundef|dead_on_unwind|dead_on_return|writable|noalias|nonnull)\b" => "",
              r"\balignstack\(\d+\)" => "", r"\brange\([^)]*\)" => "",
              r"\b(byval|sret)\(" => s"\1<", )
        d = replace(d, r)
    end
    va = nothing
    if (m = match(r" va\((.*)\)$", d)) !== nothing
        va = m.captures[1]
        d = d[1:m.offset-1]
    end
    i = findfirst('(', d)
    ret = strip(d[1:i-1])
    params = split_top(d[i+1:end-1])
    m = match(r"^((?:\w+ )*)(.*)$", ret)                # attributes before the type
    rattrs, rty = split(m.captures[1]), m.captures[2]
    flat = flatten_type(rty)
    retlist = [(widen_ret(get(equiv, t, t), opts), "") for t in flat if t != "void"]
    function plist(ps, isva = false)
        out = Tuple{String,String}[]
        eq = isva ? merge(equiv, opts.va_types) : equiv
        exts = String[]
        for p in ps
            p == "..." && (push!(out, ("...", "")); push!(exts, ""); continue)
            t, attrs = split_type(p)
            as = split(attrs)
            ext = join(filter(in(EXT_ATTRS), as), " ")
            as = filter(!in(EXT_ATTRS), as)
            # byval<T> / sret<T>: the pointee type
            pointee = nothing
            k = findfirst(a -> startswith(a, "byval<") || startswith(a, "sret<"), as)
            if k !== nothing
                kind, rest = split(join(as[k:end], " "), '<'; limit=2)
                # the pointee type runs to its matching `)`
                depth = 1; j = 0
                for (jj, c) in pairs(rest)
                    c == '(' && (depth += 1)
                    c == ')' && (depth -= 1)
                    depth == 0 && (j = jj; break)
                end
                pointee = rest[1:prevind(rest, j)]
                as = [as[1:k-1]; String(kind); split(rest[nextind(rest, j):end])]
            end
            opts.drop_byval && (as = filter(!=("byval"), as))
            opts.drop_inreg && (as = filter(!=("inreg"), as))
            opts.drop_sret && (as = filter(!=("sret"), as))
            # alignment of a byval or indirect pointer
            if !("sret" in as)
                ai = findfirst(==("align"), as)
                ai === nothing || (as = [as[1:ai-1]; as[ai+2:end]])
            end
            if "byval" in as && opts.expand_byval && pointee !== nothing
                members = flatten_type(pointee)
                if all(t -> t in ("i32", "float", "i64", "double", "ptr"), members)
                    # passed on the stack member by member
                    append!(out, [(get(eq, t, t), "") for t in members])
                    append!(exts, fill("", length(members)))
                    continue
                end
            end
            for (j, e) in enumerate(flatten_type(t))
                e = get(eq, e, e)
                isva || (e = widen_slot(e, opts))
                push!(out, (e, j == 1 ? join(sort(as), " ") : ""))
                push!(exts, j == 1 ? ext : "")
            end
        end
        return out, exts
    end
    pl, pexts = plist(params)
    vl, vexts = va === nothing ? (nothing, nothing) : plist(split_top(va), true)
    return (ret = retlist, params = pl, va = vl,
            retext = join(filter(in(EXT_ATTRS), rattrs), " "), exts = pexts, vaexts = vexts)
end

# arguments go in register-sized slots (registers or stack) on some targets: an integer
# narrower than one is the slot (extension attributes are compared on their own)
widen_slot(t, opts) = opts.slot == 0 ? t :
    (m = match(r"^i(\d+)$", t)) !== nothing && parse(Int, m.captures[1]) <= opts.slot ? "i$(opts.slot)" : t

# results come back in registers: an integer narrower than one is the register
widen_ret(t, opts) = (m = match(r"^i(\d+)$", t)) !== nothing && parse(Int, m.captures[1]) <= opts.gpr ?
    "i$(opts.gpr)" : t

# target-specific canonicalization (types LLVM lowers alike; attributes it ignores there)
canon(; types = Dict{String,String}(), va_types = Dict{String,String}(), gpr = 64, slot = 0,
      drop_byval = false, drop_sret = false, expand_byval = false, no_ext32 = false,
      drop_inreg = false) =
    (; types = merge(Dict("i1" => "i8"), types), va_types, gpr, slot, drop_byval, drop_sret,
     expand_byval, no_ext32, drop_inreg)
const CLANG_EQUIV = Dict(
    # an SSE eightbyte of two floats or halves
    "x86_64" => canon(types = Dict("<2 x float>" => "double", "<2 x half>" => "float"), slot = 64),
    # byval pointers are passed as plain pointers (LLVM copies); native code puts no
    # sret attribute on Windows (on purpose, ccall.cpp); 8-byte vectors go in GPRs,
    # 16-byte ones by reference
    "win64" => canon(drop_byval = true, drop_sret = true,
                     types = Dict("<2 x float>" => "i64", "<2 x i32>" => "i64", "<1 x double>" => "i64")),
    # everything is passed on the stack: a byval struct of 4-byte members is its members
    "i686" => canon(gpr = 32, expand_byval = true),
    "win32" => canon(gpr = 32, expand_byval = true, drop_sret = true),
    # short vectors go in SIMD registers whatever their element type
    "aarch64" => canon(slot = 64, types = Dict("<2 x float>" => "<2 x i32>", "<1 x double>" => "<2 x i32>",
                                    "<4 x float>" => "<4 x i32>", "<2 x double>" => "<4 x i32>")),
    "apple-arm64" => canon(types = Dict("<2 x float>" => "<2 x i32>", "<1 x double>" => "<2 x i32>",
                                        "<4 x float>" => "<4 x i32>", "<2 x double>" => "<4 x i32>")),
    # variadic arguments use the base standard: floating-point values in core registers
    "armv7" => canon(gpr = 32, va_types = Dict("float" => "i32", "double" => "i64")),
    "riscv64" => canon(slot = 64),
    # (native code does not extend 32-bit integers, which ELFv2 requires); clang marks a
    # single floating-point member `inreg`, which the back end ignores (same FPR)
    "ppc64le" => canon(slot = 64, no_ext32 = true, drop_inreg = true),
    "llvm" => canon(gpr = 32),
)

# whether JuliaCodegen's declaration `cg` passes everything where clang's `cl` does
function clang_match(cg::AbstractString, cl::AbstractString, target::String)
    a, b = canonical_sig(cg, target), canonical_sig(cl, target)
    (a.ret, a.params, a.va) == (b.ret, b.params, b.va) || return false
    opts = CLANG_EQUIV[target]
    # every extension clang does, JuliaCodegen does too
    for (xs, ys, ts) in ((a.exts, b.exts, a.params), (something(a.vaexts, String[]), something(b.vaexts, String[]), something(a.va, [])))
        for (x, y, t) in zip(xs, ys, ts)
            isempty(y) || x == y || (opts.no_ext32 && t[1] in ("i64", "i32")) || return false
        end
    end
    return true
end


# Where the canonical forms differ (checked to stay different). `:equivalent`: passed in
# the same registers and stack slots all the same (checked by reading llc's code for a
# call with each declaration); `:native`: native Julia's ABI differs from clang's, and
# JuliaCodegen, porting it, too.
const CLANG_KNOWN = Dict{Tuple{String,String},Tuple{Symbol,String}}(
    ("x86_64", "arg_V4d") => (:native, "a 32-byte vector is passed as <4 x double> (ymm0, assuming AVX); clang without AVX passes it in memory"),
    ("x86_64", "ret_V1d") => (:native, "a one-element FP vector is returned in memory, as GCC does; clang returns it in xmm0"),
    ("x86_64", "many_SIF") => (:equivalent, "registers exhausted: byval of 8 bytes vs i64, the same stack slot"),
    ("win64", "ret_Int128") => (:native, "Int128 is returned through a hidden pointer; clang returns it in xmm0"),
    ("win64", "arg_V4f") => (:equivalent, "byval and a 16-byte vector are both passed as a pointer to a copy"),
    ("win64", "arg_V2d") => (:equivalent, "byval and a 16-byte vector are both passed as a pointer to a copy"),
    ("win64", "arg_V4d") => (:native, "one pointer to a copy (MSVC's __m256); clang without AVX splits it into two"),
    ("i686", "arg_V2f") => (:equivalent, "byval and the vector take the same 8 stack bytes"),
    ("i686", "arg_V2i") => (:equivalent, "byval and the vector take the same 8 stack bytes"),
    ("i686", "ret_V2f") => (:native, "every aggregate but ComplexF32 is returned through sret; clang returns 8-byte vectors in registers"),
    ("i686", "ret_V2i") => (:native, "every aggregate but ComplexF32 is returned through sret; clang returns 8-byte vectors in registers"),
    ("win32", "arg_V2f") => (:equivalent, "byval and the vector take the same stack bytes"),
    ("win32", "arg_V4f") => (:equivalent, "byval and the vector take the same stack bytes"),
    ("win32", "arg_V2d") => (:equivalent, "byval and the vector take the same stack bytes"),
    ("win32", "arg_V1d") => (:equivalent, "byval and the vector take the same stack bytes"),
    ("win32", "arg_V2i") => (:equivalent, "byval and the vector take the same stack bytes"),
    ("win32", "ret_V2i") => (:equivalent, "i64 and <2 x i32> are both returned in edx:eax"),
    ("win32", "ret_V4f") => (:equivalent, "a hidden result pointer either way (LLVM demotes the vector result)"),
    ("win32", "ret_V2d") => (:equivalent, "a hidden result pointer either way (LLVM demotes the vector result)"),
    ("win32", "ret_V2f") => (:native, "an 8-byte vector is returned as i64 (edx:eax); clang returns it on the x87 stack"),
    ("win32", "ret_V1d") => (:native, "an 8-byte vector is returned as i64 (edx:eax); clang returns it on the x87 stack"),
    ("armv7", "arg_S72") => (:equivalent, "[9 x i64] and byval both go in r2-r3 and 64 stack bytes"),
    ("armv7", "arg_SHF") => (:native, "a struct of Float16s is a VFP homogeneous aggregate; clang passes it in core registers"),
    ("armv7", "ret_SHF") => (:native, "a struct of Float16s is a VFP homogeneous aggregate; clang returns it in r0"),
    ("armv7", "ret_V4d") => (:native, "a 32-byte vector of doubles is returned as a homogeneous aggregate in d0-d3; clang through sret"),
    ("armv7", "arg_V2i") => (:native, "an 8-byte integer vector is passed in core registers; clang in d0"),
    ("armv7", "ret_V2i") => (:native, "an 8-byte integer vector is returned through sret; clang in d0"),
    ("armv7", "arg_SV4V4") => (:native, "no homogeneous vector aggregates on ARM: core registers; clang q0-q1"),
    ("armv7", "ret_SV4V4") => (:native, "no homogeneous vector aggregates on ARM: sret; clang q0-q1"),
    ("aarch64", "ret_V4d") => (:native, "sret alignment 32, Julia's alignment of the vector (the host's); 16 in C"),
    ("apple-arm64", "ret_V4d") => (:native, "sret alignment 32, Julia's alignment of the vector (the host's); 16 in C"),
    ("ppc64le", "arg_V2f") => (:native, "an 8-byte vector is a homogeneous vector aggregate (vector register); clang passes it as i64 in a GPR"),
    ("ppc64le", "ret_V2f") => (:native, "an 8-byte vector is a homogeneous vector aggregate (vector register); clang returns it as i64 in a GPR"),
    ("ppc64le", "arg_V1d") => (:native, "an 8-byte vector is a homogeneous vector aggregate (vector register); clang passes it as i64 in a GPR"),
    ("ppc64le", "ret_V1d") => (:native, "an 8-byte vector is a homogeneous vector aggregate (vector register); clang returns it as i64 in a GPR"),
    ("ppc64le", "arg_V2i") => (:native, "an 8-byte vector is a homogeneous vector aggregate (vector register); clang passes it as i64 in a GPR"),
    ("ppc64le", "ret_V2i") => (:native, "an 8-byte vector is a homogeneous vector aggregate (vector register); clang returns it as i64 in a GPR"),
    ("ppc64le", "arg_V4d") => (:native, "a 32-byte vector is passed by value in GPRs ([2 x i128]); clang by reference"),
)

# --- the tests -----------------------------------------------------------------------------

const EXPECTED_FILE = joinpath(@__DIR__, "cabi_targets.txt")

function read_expected()
    d = Dict{Tuple{String,String},Tuple{String,String}}()
    isfile(EXPECTED_FILE) || return d
    for l in eachline(EXPECTED_FILE)
        (isempty(l) || startswith(l, "#")) && continue
        t, c, cs, cf = split(l, '\t')
        d[(t, c)] = (cs, cf)
    end
    return d
end

strip_retext(s) = replace(s, r"^(signext|zeroext) " => "")

@testset "C ABI per target" begin
    regen = get(ENV, "JULIACODEGEN_CABI_REGEN", "0") == "1"
    expected = read_expected()
    out = String["# JuliaCodegen's C signatures per target (test/cabi_targets.jl):",
                 "# target, case, ccall signature, cfunction signature (- for none)"]
    for (tname, triple, skip) in TARGETS
        cases = filter(c -> !skip_case(c, skip), CASES)
        # (the LLVM fallback is LLVM's lowering of Julia's types, not a C ABI)
        cl = CLANG === nothing || tname == "llvm" ? nothing : clang_decls(cases, triple)
        @testset "$tname" begin
            for c in cases
                cs, cf = codegen_sigs(c, triple)
                cfs = something(cf, "-")
                push!(out, join((tname, c[1], cs, cfs), '\t'))
                @test !startswith(cs, "unsupported")
                # a cfunction has the signature of the ccall (its result extended)
                cf === nothing || @test strip_retext(cf) == strip_retext(cs)
                if !regen
                    exp = get(expected, (tname, c[1]), nothing)
                    @test exp !== nothing && exp[1] == cs
                    @test exp[2] == cfs
                end
                cl === nothing && continue
                m = clang_match(cs, cl[c[1]], tname)
                if haskey(CLANG_KNOWN, (tname, c[1]))
                    @test !m
                else
                    @test m
                end
            end
        end
    end
    regen && write(EXPECTED_FILE, join(out, '\n') * '\n')
end
