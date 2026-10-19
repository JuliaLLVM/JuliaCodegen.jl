# Helpers shared by the test files: differential execution against Julia's native code
# generator (`@cgtest`) and verification of emitted LLVM IR (`verify_ir`).

using Test
using LLVM, LLVM.IR, LLVM.Passes
using JuliaIR
import Libdl

## differential execution

"""
    Outcome(kind, expected, got)

The result of a differential check. `kind` is `:ok`, or what differs between the native
execution (`expected`) and the compiled one (`got`):

- `:value`: the results are not `isequal`;
- `:type`: the results are `isequal`, but of different types;
- `:exception`: one of the two threw, or both threw exceptions of different types;
- `:arguments`: the results agree, but the arguments were mutated differently (`expected`
  and `got` are then the arguments after the call).
"""
struct Outcome
    kind::Symbol
    expected::Any
    got::Any
end

const OK = Outcome(:ok, nothing, nothing)

Base.:(==)(a::Outcome, b::Outcome) = a.kind === b.kind && (a.kind === :ok ||
    (isequal(a.expected, b.expected) && isequal(a.got, b.got)))

function Base.show(io::IO, o::Outcome)
    if o.kind === :ok
        print(io, "Outcome(:ok)")
    else
        print(io, "Outcome(:", o.kind, ", expected = ")
        show_result(io, o.expected)
        print(io, ", got = ")
        show_result(io, o.got)
        print(io, ")")
    end
end

show_result(io, x::Exception) = print(io, "exception ", typeof(x))
show_result(io, x) = (show(io, x); print(io, "::", typeof(x)))

struct Threw
    exception::Any
end

function run_isolated(run, f, args)
    args = deepcopy(args)
    result = try
        run(f, args...)
    catch err
        Threw(err)
    end
    return result, args
end

"""
    differential(run, f, args...; gc=gc_stress()) -> Outcome

Run `f(args...)` with Julia's native code and with `run(f, args...)`, each on its own deep
copy of `args`, and compare the results, their types (for exceptions: only the type of
the exception) and the arguments after the call. With `gc`, a full collection runs before
each of the two calls.
"""
function differential(run, f, args...; gc::Bool=gc_stress())
    gc && GC.gc()
    expected, expected_args = run_isolated(Base.invokelatest, f, args)
    gc && GC.gc()
    got, got_args = run_isolated(run, f, args)

    if expected isa Threw || got isa Threw
        if !(expected isa Threw && got isa Threw)
            return Outcome(:exception, unwrap(expected), unwrap(got))
        end
        typeof(expected.exception) === typeof(got.exception) ||
            return Outcome(:exception, expected.exception, got.exception)
    else
        isequal(expected, got) || return Outcome(:value, expected, got)
        typeof(expected) === typeof(got) || return Outcome(:type, expected, got)
    end
    isequal(expected_args, got_args) || return Outcome(:arguments, expected_args, got_args)
    return OK
end

unwrap(x) = x isa Threw ? x.exception : x

"Whether `JULIACODEGEN_GC_STRESS=1` asks for a full collection before every execution."
gc_stress() = get(ENV, "JULIACODEGEN_GC_STRESS", "0") == "1"

"""
The function that runs code compiled by JuliaCodegen in `@cgtest`. There is none yet: the
compiler is added piece by piece, and this is set once it can run code.
"""
function cgrun(f, args...)
    error("JuliaCodegen cannot run code yet")
end

"""
    @cgtest f(args...)
    @cgtest run=r f(args...)

Test that code compiled by JuliaCodegen (or by the runner `r`, a function called as
`r(f, args...)`) behaves like native code for `f(args...)`, see [`differential`](@ref).
"""
macro cgtest(exs...)
    ex = last(exs)
    Meta.isexpr(ex, :call) || error("@cgtest expects a call, got $ex")
    run = :cgrun
    for kw in exs[1:end-1]
        Meta.isexpr(kw, :(=)) && kw.args[1] === :run ||
            error("@cgtest: unknown option $kw")
        run = kw.args[2]
    end
    f = ex.args[1]
    args = ex.args[2:end]
    any(a -> Meta.isexpr(a, (:kw, :parameters, :...)), args) &&
        error("@cgtest: keyword arguments and splatting are not supported")
    :(@test differential($(esc(run)), $(esc(f)), $(map(esc, args)...)) == OK)
end

## IR verification

"Whether this Julia and LLVM.jl provide the Julia dialect's verifier."
function has_dialect_verifier()
    isdefined(LLVM.Interop, :verify_dialect) || return false
    lib = Libdl.dlopen("libjulia-codegen", throw_error=false)
    lib === nothing && return false
    return Libdl.dlsym_e(lib, :JLDialectsVerifyModule) != C_NULL
end

"""
    verify_ir(mod; julia=VERSION, strong=true, dialect=has_dialect_verifier())

Verify a module in Julia's pre-lowering IR: LLVM's verifier, then JuliaIR's
GCInvariantVerifier for the IR dialect of `julia` (throwing a `PassException` wrapping a
`JuliaIR.GCInvariantError`), and, with `dialect`, the Julia dialect's verifier.
"""
function verify_ir(mod::LLVM.Module; julia::VersionNumber=VERSION, strong::Bool=true,
                   dialect::Bool=has_dialect_verifier())
    LLVM.verify(mod)
    run!(JuliaIR.GCInvariantVerifierPass(; julia, strong), mod)
    dialect && LLVM.Interop.verify_dialect(mod)
    return mod
end
