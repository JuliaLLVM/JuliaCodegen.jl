# The specsig convention: the declarations of the entries are native code's, and code
# calls through it both ways: from a jlcall entry into JuliaCodegen's specsig entry, and
# into the natively compiled function (its `specptr`).

struct SS_Pair; a::Float64; b::Float64; end
struct SS_One; a::Float64; end
struct SS_Small; a::Bool; b::Int8; end
struct SS_Empty; end
struct SS_Ref; n::Int; s::String; end
primitive type SS_P24 24 end
const SS_V4 = NTuple{4,VecElement{Float32}}

ss_id(x) = x
ss_swap(x::SS_Pair) = SS_Pair(x.b, x.a)
ss_mix(a::Int8, b::Bool, c::UInt16, d::Float32, e::SS_Pair, f::Nothing, g::String) =
    (Int(a) + b + c + d + e.a + e.b, sizeof(g))
ss_fst(x, y) = x
ss_dup(x) = (x, x)
ss_widen(x::Int64) = Int128(x) << 64
ss_maybe(x::Union{Nothing,Int}) = x === nothing ? 0 : x
ss_box(x::Int) = Ref(x)
ss_throw(x) = throw(ArgumentError("ss_throw $x"))
ss_vec(v::SS_V4) = map(x -> VecElement(x.value * 2f0), v)
@noinline ss_vararg(xs...) = length(xs)

# The first function definition's header in native code for `f(::types...)`, without
# names: the convention, the result and the parameters with their attributes.
function native_specsig_header(@nospecialize(f), @nospecialize(types))
    ir = sprint(io -> code_llvm(io, f, types; raw=true, optimize=false, debuginfo=:none))
    return normalize_header(something(match(r"^define .*$"m, ir)).match)
end

function normalize_header(line)
    line = replace(line, r"^define " => "")
    line = replace(line, r" #\d+ .*$" => "")                    # the attributes, metadata
    line = replace(line, r"@\"?[^\"(]+\"?\(" => "@f(")         # the name
    line = replace(line, r"%\"[^\"]*\"" => "")                   # the parameter names
    line = replace(line, r"%[-\w.$]+" => "")
    return replace(line, r" +([,)])" => s"\1")
end

"JuliaCodegen's specsig entry `ss_entry` for `f(::types...)`."
function specsig_ir(@nospecialize(f), @nospecialize(types))
    @dispose ctx=LLVM.Context() mod=LLVM.Module("jcspecsig") begin
        cgm = JuliaCodegen.CGModule(mod, test_config())
        info, _ = JuliaCodegen.emit_entry!(cgm, Tuple{Core.Typeof(f), types...})
        w = JuliaCodegen.emit_specsig_wrapper!(cgm, info, "ss_entry")
        verify_ir(mod)
        return string(w)
    end
end

specsig_header(@nospecialize(f), @nospecialize(types)) =
    normalize_header(something(match(r"^define .*$"m, specsig_ir(f, types))).match)

# A jlcall entry `name` that calls `callee`, a function in the specsig convention with
# the signature `sig`.
function emit_specsig_caller!(cgm, mi, sig, callee, name)
    T_tracked = JuliaCodegen.T_tracked()
    ft = LLVM.FunctionType(T_tracked, [T_tracked, JuliaCodegen.T_ptr(), LLVM.Int32Type()])
    f = LLVM.Function(cgm.mod, name, ft)
    JuliaCodegen.init_function!(f, cgm.config.target)
    info = JuliaCodegen.FuncInfo(mi, f, sig.argtypes, sig.rettype)
    @dispose b=LLVM.IRBuilder() begin
        top = LLVM.BasicBlock(f, "top")
        LLVM.position!(b, LLVM.at_end(top))
        fc = JuliaCodegen.FnCtx(cgm, info, nothing, b, top)
        JuliaCodegen.emit_prologue!(fc; safepoint=false)
        F, argv, _ = LLVM.parameters(f)
        args = map(enumerate(sig.argtypes)) do (i, T)
            i == 1 && return JuliaCodegen.boxed(T, F)
            slot = LLVM.gep!(b, T_tracked, argv, [LLVM.ConstantInt(LLVM.Int64Type(), i - 2)])
            JuliaCodegen.boxed(T, LLVM.load!(b, T_tracked, slot))
        end
        r = JuliaCodegen.emit_specsig_call!(fc, sig, callee, args)
        if r.kind === JuliaCodegen.Bottom
            LLVM.unreachable!(b)
        else
            LLVM.ret!(b, JuliaCodegen.emit_box(fc, r))
        end
    end
    return f
end

# JuliaCodegen's specsig entry, called from a jlcall entry
function emit_through_specsig!(cgm, @nospecialize(tt), name)
    info, _ = JuliaCodegen.emit_entry!(cgm, tt; name=name * "_jlcall")
    w = JuliaCodegen.emit_specsig_wrapper!(cgm, info, name * "_specsig")
    sig = JuliaCodegen.specsig_abi(cgm, info.argtypes, info.rettype)
    emit_specsig_caller!(cgm, info.mi, sig, w, name)
end

# the natively compiled function, called from a jlcall entry
function emit_native_specsig_call!(cgm, @nospecialize(tt), name)
    mi = JuliaCodegen.method_instance(tt, cgm.world)
    ci = mi.cache
    while ci.specptr == C_NULL || !(ci.min_world <= cgm.world <= ci.max_world)
        # (functions that return a constant have no code)
        isdefined(ci, :next) || error("no native code in the specsig convention for ", tt)
        ci = ci.next
    end
    sig = JuliaCodegen.specsig_abi(cgm, JuliaCodegen.signature_argtypes(mi), ci.rettype)
    iptr = LLVM.IntType(8 * sizeof(Ptr{Cvoid}))
    callee = LLVM.const_inttoptr(LLVM.ConstantInt(iptr, UInt(ci.specptr)), JuliaCodegen.T_ptr())
    emit_specsig_caller!(cgm, mi, sig, callee, name)
end

run_through_specsig(f, args...) = cgrun(f, args...; emit=emit_through_specsig!)
run_native_specsig(f, args...) = cgrun(f, args...; emit=emit_native_specsig_call!)

const SS_CASES = [
    (ss_id, (Int,)), (ss_id, (Int8,)), (ss_id, (Bool,)), (ss_id, (UInt16,)), (ss_id, (Char,)),
    (ss_id, (Float32,)), (ss_id, (Float16,)), (ss_id, (Ptr{Int},)), (ss_id, (Int128,)),
    (ss_id, (SS_P24,)), (ss_id, (SS_Pair,)), (ss_id, (SS_One,)), (ss_id, (SS_Small,)),
    (ss_id, (Tuple{Int},)), (ss_id, (NTuple{2,Int},)), (ss_id, (SS_V4,)), (ss_id, (SS_Empty,)),
    (ss_id, (Nothing,)), (ss_id, (String,)), (ss_id, (Symbol,)), (ss_id, (Any,)),
    (ss_id, (Type{Int},)), (ss_swap, (SS_Pair,)),
    (ss_mix, (Int8, Bool, UInt16, Float32, SS_Pair, Nothing, String)),
    (ss_fst, (Int, SS_Empty)), (ss_dup, (Int,)), (ss_widen, (Int64,)), (ss_maybe, (Union{Nothing,Int},)),
    (ss_box, (Int,)), (ss_throw, (Int,)), (ss_vec, (SS_V4,)),
]

@testset "specsig" begin

@testset "declarations" begin
    for (f, types) in SS_CASES
        @test specsig_header(f, types) == native_specsig_header(f, types)
    end
    # the pgcstack argument, which provides the GC stack from Julia 1.13 on
    ir = specsig_ir(ss_id, (Int,))
    if test_config().dialect.gc_stack_argument
        @test @filecheck begin
            @check "define swiftcc i64 @ss_entry(ptr nonnull swiftself \"gcstack\" %0, i64 signext %1)"
            ir
        end
    else
        @test @filecheck begin
            @check "define swiftcc i64 @ss_entry(ptr nonnull swiftself %0, i64 signext %1)"
            ir
        end
    end
end

@testset "unsupported" begin
    # inline values with references are passed with their roots, unions returned with
    # their payload separately
    @test_throws JuliaCodegen.Unsupported specsig_header(ss_id, (SS_Ref,))
    @test_throws JuliaCodegen.Unsupported specsig_header(ss_id, (Union{Nothing,Int},))
    @test_throws JuliaCodegen.Unsupported specsig_header(ss_vararg, (Int, Int))
end

@testset "calls through the convention" begin
    for run in (run_through_specsig, run_native_specsig)
        @cgtest run=run ss_id(42)
        @cgtest run=run ss_id(Int8(-3))
        @cgtest run=run ss_id(true)
        @cgtest run=run ss_id(0xfffe)
        @cgtest run=run ss_id('λ')
        @cgtest run=run ss_id(Int128(-5) << 70)
        @cgtest run=run ss_id(SS_Pair(1.5, 2.5))
        @cgtest run=run ss_id(SS_One(3.0))
        @cgtest run=run ss_id(SS_Small(true, Int8(-1)))
        @cgtest run=run ss_id((1, 2))
        @cgtest run=run ss_id("a string")
        @cgtest run=run ss_swap(SS_Pair(1.0, 2.0))
        @cgtest run=run ss_mix(Int8(1), true, 0x0003, 4f0, SS_Pair(5.0, 6.0), nothing, "seven")
        @cgtest run=run ss_dup(7)
        @cgtest run=run ss_widen(9)
        @cgtest run=run ss_box(10)
        @cgtest run=run ss_throw(11)
        @cgtest run=run ss_vec(map(VecElement, (1f0, 2f0, 3f0, 4f0)))
    end
    # (native code for these returns a constant, without code in the convention)
    @cgtest run=run_through_specsig ss_id(SS_Empty())
    @cgtest run=run_through_specsig ss_id(nothing)
    @cgtest run=run_through_specsig ss_id(Int)
end

end
