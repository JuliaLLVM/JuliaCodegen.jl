# The state of a compilation: one `CGModule` per LLVM module, one `FnCtx` per function.

"""
    JuliaCodegen.FuncInfo

An LLVM function emitted for a `MethodInstance`, in JuliaCodegen's internal calling
convention: ghost arguments are dropped, the others are passed in their representation
(inline values by value, boxed ones as tracked pointers, unboxed unions as their union
type), and the result is returned in the representation of the inferred return type
(`void` for ghosts and `Union{}`).
"""
struct FuncInfo
    mi::Core.MethodInstance
    llvmf::LLVM.Function
    argtypes::Vector{Any}
    rettype::Any
end

"""
    JuliaCodegen.CGModule(mod::LLVM.Module, config::CodegenConfig; world)

The state of generating code into the LLVM module `mod` (in the LLVM context it was
created in): the functions emitted for method instances, the objects the code refers to,
and the per-context type layouts and TBAA metadata. Names are numbered per module, so that
generating the same code twice gives the same IR.
"""
mutable struct CGModule
    mod::LLVM.Module
    config::CodegenConfig
    world::UInt
    layouts::Layouts
    tbaa::TBAA
    funcs::IdDict{Core.MethodInstance,FuncInfo}
    worklist::Vector{Tuple{FuncInfo,Any}}
    "The objects the code refers to, by the global that holds each one's address."
    literals::IdDict{Any,LLVM.GlobalVariable}
    counter::Int
end

function CGModule(mod::LLVM.Module, config::CodegenConfig; world::UInt=Base.get_world_counter())
    mod.triple = config.target.triple
    mod.datalayout = config.target.datalayout
    return CGModule(mod, config, world, Layouts(config), TBAA(config.dialect),
                    IdDict{Core.MethodInstance,FuncInfo}(), Tuple{FuncInfo,Any}[],
                    IdDict{Any,LLVM.GlobalVariable}(), 0)
end

"A name that is unique in the module, from `prefix` and the function `f` (if any)."
function unique_name(cgm::CGModule, prefix::AbstractString, @nospecialize(f=nothing))
    cgm.counter += 1
    s = f isa Function ? string(prefix, "_", nameof(f), "_", cgm.counter) :
                         string(prefix, "_", cgm.counter)
    return replace(s, r"[^A-Za-z0-9_.]" => "_")
end

"""
    JuliaCodegen.FnCtx

The state of emitting one LLVM function: the IR, the builder, the value of each argument
and statement, the LLVM block of each IR block and the edges into it, and the phis to
fill in once every block is emitted.
"""
mutable struct FnCtx <: AbstractFnCtx
    cgm::CGModule
    info::FuncInfo
    ir::Any
    builder::LLVM.IRBuilder
    args::Vector{CGVal}
    ssavals::Vector{Union{Nothing,CGVal}}
    blocks::Vector{LLVM.BasicBlock}
    "The edges into each IR block that were emitted: (IR predecessor, LLVM block)."
    edges::Vector{Vector{Tuple{Int,LLVM.BasicBlock}}}
    "The phis: (statement, IR block, phi)."
    phis::Vector{Tuple{Int,Int,LLVM.Instruction}}
    cur_block::Int
    "The entry block, for allocas and the loads of objects."
    top::LLVM.BasicBlock
    current_task::Union{Nothing,LLVM.Value}
    "The objects loaded at the top of the function, by object."
    loaded::IdDict{Any,LLVM.Value}
end

function FnCtx(cgm::CGModule, info::FuncInfo, ir, builder::LLVM.IRBuilder, top::LLVM.BasicBlock)
    n = ir === nothing ? 0 : length(ir.stmts)
    nb = ir === nothing ? 0 : length(ir.cfg.blocks)
    return FnCtx(cgm, info, ir, builder, CGVal[], Vector{Union{Nothing,CGVal}}(nothing, n),
                 LLVM.BasicBlock[], [Tuple{Int,LLVM.BasicBlock}[] for _ in 1:nb],
                 Tuple{Int,Int,LLVM.Instruction}[], 0, top, nothing, IdDict{Any,LLVM.Value}())
end

config(fc::FnCtx) = fc.cgm.config
dialect(fc::FnCtx) = fc.cgm.config.dialect
call_op!(fc::FnCtx, op::AbstractString, args::LLVM.Value...; name::AbstractString="") =
    call_op!(fc.builder, fc.cgm.mod, dialect(fc), op, args...; name)
tbaa!(fc::FnCtx, inst::LLVM.Instruction, kind::Symbol) = tbaa!(fc.cgm.tbaa, inst, kind)
value_type(fc::FnCtx, @nospecialize(T)) = value_type(fc.cgm.layouts, T)
layout(fc::FnCtx, @nospecialize(T)) = layout(fc.cgm.layouts, T)

current_block(b::LLVM.IRBuilder) = LLVM.BasicBlock(LLVM.API.LLVMGetInsertBlock(b))
current_function(fc::FnCtx) = current_block(fc.builder).parent
