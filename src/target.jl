# The target code is generated for.

"""
The address spaces of Julia's pointers in its LLVM IR: GC-tracked objects (`Tracked`),
pointers derived from them (`Derived`), objects rooted by the callee (`CalleeRooted`), and
pointers loaded from tracked objects (`Loaded`). They are non-integral (`-ni:10:11:12:13`
in the data layout).
"""
module AddrSpace
const Tracked = 10
const Derived = 11
const CalleeRooted = 12
const Loaded = 13
end

const NONINTEGRAL = "-ni:10:11:12:13"

"""
    JuliaCodegen.Target(; triple, cpu="", features="", datalayout=nothing)

The target code is generated for: an LLVM target triple, CPU and features, and the data
layout of the target with Julia's non-integral address spaces. Without `datalayout`, it
comes from the target machine of the triple, or, for targets whose back end the LLVM
library lacks, from a table of clang's data layouts.

The C ABI of `ccall` and `@cfunction` is the target's (`c_abi`), so code can be emitted for
any target on any host. Julia's own layouts of types are the host's: on targets whose
data layout differs, only types laid out the same are meaningful.

See [`JuliaCodegen.host_target`](@ref) for the target of Julia's JIT.
"""
struct Target
    "The normalized target triple."
    triple::String
    cpu::String
    features::String
    "The data layout, with Julia's non-integral address spaces."
    datalayout::String
    "The size of a pointer in bytes."
    pointer_size::Int
    "The C ABI, see [`JuliaCodegen.c_abi_kind`](@ref)."
    c_abi::Symbol
end

function Target(; triple::AbstractString, cpu::AbstractString="",
                features::AbstractString="",
                datalayout::Union{Nothing,AbstractString}=nothing)
    triple = LLVM.normalize(triple)
    dl = datalayout === nothing ? target_datalayout(triple) : String(datalayout)
    occursin(NONINTEGRAL, dl) || (dl *= NONINTEGRAL)
    pointer_size = LLVM.DataLayout(LLVM.pointersize, dl)
    return Target(triple, String(cpu), String(features), dl, pointer_size,
                  c_abi_kind(triple))
end

function Base.show(io::IO, t::Target)
    print(io, "JuliaCodegen.Target(triple=")
    show(io, t.triple)
    isempty(t.cpu) || (print(io, ", cpu="); show(io, t.cpu))
    print(io, ")")
end

"""
    JuliaCodegen.host_target() -> Target

The target of Julia's JIT: the host's triple, CPU and features. On Windows, the JIT
uses ELF objects (`FORCE_ELF` in Julia's `src/jitlayers.cpp`), which the triple says.
"""
host_target() = HOST_TARGET()

const HOST_TARGET = OncePerProcess{Target}() do
    triple = LLVM.default_triple()
    Sys.iswindows() && !endswith(triple, "-elf") && (triple *= "-elf")
    Target(; triple, cpu=LLVM.host_cpu_name(), features=LLVM.host_cpu_features())
end

"""
    JuliaCodegen.c_abi_kind(triple) -> Symbol

The C ABI of a target triple, named after the ABI implementations in Julia's `src/abi_*.cpp`:
`:x86_64` (System V), `:win64`, `:x86` (System V), `:win32`, `:aarch64` (including Apple's
arm64), `:arm`, `:riscv64`, `:ppc64le`, or `:llvm` (the fallback of `abi_llvm.cpp`).
"""
function c_abi_kind(triple::AbstractString)
    arch, rest = let parts = split(lowercase(triple), '-'; limit=2)
        parts[1], get(parts, 2, "")
    end
    windows = occursin(r"windows|mingw|win32|cygwin", rest)
    if arch in ("x86_64", "amd64")
        return windows ? :win64 : :x86_64
    elseif occursin(r"^i[3-6]86$", arch)
        return windows ? :win32 : :x86
    elseif arch in ("aarch64", "arm64", "aarch64_be", "arm64e")
        return :aarch64
    elseif startswith(arch, "arm") || startswith(arch, "thumb")
        return :arm
    elseif arch == "riscv64"
        return :riscv64
    elseif arch in ("powerpc64le", "ppc64le")
        return :ppc64le
    else
        return :llvm
    end
end

# The data layouts of targets whose back end Julia's LLVM may lack, as clang reports them.
const C_TARGET_DATALAYOUTS = Dict(
    :x86_64 => "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128",
    :win64 => "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128",
    :x86 => "e-m:e-p:32:32-p270:32:32-p271:32:32-p272:64:64-i128:128-f64:32:64-f80:32-n8:16:32-S128",
    :win32 => "e-m:x-p:32:32-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:32-n8:16:32-a:0:32-S32",
    :aarch64 => "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32",
    :arm => "e-m:e-p:32:32-Fi8-i64:64-v128:64:128-a:0:32-n32-S64",
    :riscv64 => "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128",
    :ppc64le => "e-m:e-Fn32-i64:64-i128:128-n32:64-S128-v256:256:256-v512:512:512",
)

const INITIALIZE_TARGETS = OncePerProcess{Nothing}() do
    LLVM.InitializeAllTargetInfos()
    LLVM.InitializeAllTargets()
    LLVM.InitializeAllTargetMCs()
    nothing
end

"Whether the LLVM library has a back end for `triple`."
function has_backend(triple::AbstractString)
    INITIALIZE_TARGETS()
    try
        LLVM.Target(; triple)
        return true
    catch err
        err isa ArgumentError || rethrow()
        return false
    end
end

# The data layout of `triple`, without Julia's address spaces: its target machine's if the
# LLVM library has the back end, else the table above.
function target_datalayout(triple::AbstractString)
    if has_backend(triple)
        LLVM.TargetMachine(LLVM.Target(; triple), triple) do tm
            LLVM.DataLayout(string, tm)
        end
    else
        dl = get(C_TARGET_DATALAYOUTS, c_abi_kind(triple), nothing)
        dl === nothing &&
            throw(ArgumentError("no data layout is known for target $triple; pass one"))
        dl
    end
end

"""
    JuliaCodegen.target_machine(f, target::Target; opt_level=LLVM.API.LLVMCodeGenLevelDefault)

Call `f` with a target machine for `target` (for the optimization pipeline, whose
vectorizers need its cost model), and dispose of it afterwards.
"""
function target_machine(f, target::Target;
                        opt_level::LLVM.API.LLVMCodeGenOptLevel=LLVM.API.LLVMCodeGenLevelDefault)
    has_backend(target.triple) ||
        throw(ArgumentError("the LLVM library has no back end for $(target.triple)"))
    LLVM.TargetMachine(f, LLVM.Target(; target.triple), target.triple; target.cpu,
                       target.features, opt_level)
end
