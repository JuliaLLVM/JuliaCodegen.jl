# What a compilation produces, besides the LLVM module: its entry points, the objects and
# external symbols its code refers to, and the functions that call native code instead.
# The module is relocatable: it embeds no addresses, so whoever links it (a JIT, an image
# builder) binds the objects and symbols it lists. And the passes that lower it.

"""
    JuliaCodegen.CodegenOutput

What [`codegen_output`](@ref JuliaCodegen.codegen_output) reports about a module:

- `entries`: its entry points (see [`Entry`](@ref JuliaCodegen.Entry));
- `literals`: the objects the code refers to, by the name of the global (declared without
  a value) that must hold each one's address, in the order of the names;
- `symbols`: the external functions and globals the code refers to by name: the runtime's
  (`ijl_*`, `jl_world_counter`, ...) and C symbols (but `julia.*` and `llvm.*`
  intrinsics, which passes lower);
- `fallbacks`: the functions that call native code instead, and why.
"""
struct CodegenOutput
    entries::Vector{Entry}
    literals::Vector{Pair{String,Any}}
    symbols::Vector{String}
    fallbacks::Vector{Pair{Core.MethodInstance,Any}}
end

"""
    JuliaCodegen.codegen_output(cgm) -> CodegenOutput

What the module of `cgm` contains and refers to, see
[`CodegenOutput`](@ref JuliaCodegen.CodegenOutput).
"""
function codegen_output(cgm::CGModule)
    literals = sort!(literal_objects(cgm); by=first)
    return CodegenOutput(copy(cgm.entries), literals, external_symbols(cgm.mod, literals),
                         copy(cgm.fallbacks))
end

is_intrinsic_name(name::AbstractString) = startswith(name, "llvm.") || startswith(name, "julia.")

# the names of the functions and globals `mod` declares but doesn't define, but
# intrinsics and the globals of `literals`
function external_symbols(mod::LLVM.Module, literals)
    names = Set{String}(first.(literals))
    syms = String[]
    for f in LLVM.functions(mod)
        LLVM.isdeclaration(f) && !is_intrinsic_name(LLVM.name(f)) && push!(syms, LLVM.name(f))
    end
    for gv in LLVM.globals(mod)
        LLVM.isdeclaration(gv) && !(LLVM.name(gv) in names) && push!(syms, LLVM.name(gv))
    end
    return sort!(syms)
end

"""
    JuliaCodegen.check_relocatable(mod, config) -> Vector{String}

The reasons the module `mod` is not relocatable, if any: the addresses it embeds, as
pointers made from integer constants (`inttoptr`), but the small type tags of builtin
types, which are not addresses. Code generated from IR that has pointer constants (a
`Ptr` value known at compile time) embeds them.
"""
function check_relocatable(mod::LLVM.Module, config::CodegenConfig)
    max_tag = UInt(config.runtime.max_small_tag) << 4
    problems = String[]
    seen = Set{LLVM.Constant}()
    function visit(c::LLVM.Constant, where)
        c in seen && return
        push!(seen, c)
        c isa LLVM.GlobalValue && return
        if c isa LLVM.ConstantExpr && LLVM.API.LLVMGetConstOpcode(c) == LLVM.API.LLVMIntToPtr
            v = LLVM.operands(c)[1]
            if !(v isa LLVM.ConstantInt) || convert(UInt, v) >= max_tag
                push!(problems, "the address $(string(c)) in $where")
            end
        end
        for op in LLVM.operands(c)
            op isa LLVM.Constant && visit(op, where)
        end
    end
    for f in LLVM.functions(mod), bb in LLVM.blocks(f), inst in LLVM.instructions(bb)
        for op in LLVM.operands(inst)
            op isa LLVM.Constant && visit(op, "@" * LLVM.name(f))
        end
    end
    for gv in LLVM.globals(mod)
        LLVM.isdeclaration(gv) || visit(LLVM.initializer(gv), "@" * LLVM.name(gv))
    end
    return problems
end

## pipelines

"""
    JuliaCodegen.Pipeline

The passes that lower a module of Julia's IR (the IR JuliaCodegen generates) to plain
LLVM IR, run by [`run_pipeline!`](@ref JuliaCodegen.run_pipeline!):

- [`JuliaCppPipeline`](@ref JuliaCodegen.JuliaCppPipeline): Julia's own pipeline, the
  default;
- [`NoPipeline`](@ref JuliaCodegen.NoPipeline): none, for whoever runs its own (Julia's
  JIT, GPUCompiler.jl);
- [`CustomPipeline`](@ref JuliaCodegen.CustomPipeline): a function of the module and a
  target machine, e.g. one running JuliaIR.jl's passes.
"""
abstract type Pipeline end

"""
    JuliaCodegen.JuliaCppPipeline(; opt_level=2)

The running Julia's own pass pipeline (its C++ passes, as `LLVM.Interop.JuliaPipeline`)
at optimization level `opt_level`, for the host (whose target machine it runs with).
"""
Base.@kwdef struct JuliaCppPipeline <: Pipeline
    opt_level::Int = 2
end

"""
    JuliaCodegen.NoPipeline()

No passes: the module stays in Julia's IR.
"""
struct NoPipeline <: Pipeline end

"""
    JuliaCodegen.CustomPipeline(f)

The passes `f(mod, tm)` runs on the module `mod` with the target machine `tm`.
"""
struct CustomPipeline <: Pipeline
    f::Any
end

"""
    JuliaCodegen.run_pipeline!(pipeline, mod, config)

Run the passes of `pipeline` on the module `mod`, generated with the configuration
`config`, with a target machine for its target.
"""
run_pipeline!(::NoPipeline, mod::LLVM.Module, config::CodegenConfig) = mod

function run_pipeline!(p::JuliaCppPipeline, mod::LLVM.Module, config::CodegenConfig)
    target_machine(config.target) do tm
        LLVM.run!(LLVM.Interop.JuliaPipeline(; opt_level=p.opt_level), mod, tm)
    end
    return mod
end

function run_pipeline!(p::CustomPipeline, mod::LLVM.Module, config::CodegenConfig)
    target_machine(tm -> p.f(mod, tm), config.target)
    return mod
end
