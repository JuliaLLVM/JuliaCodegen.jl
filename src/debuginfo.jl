# Debug information: the line tables of native code (`debug_info_kind` above `NoDebug`):
# a compile unit for the module, a subprogram for every function, and for every
# statement the location of its line, with the functions inlined into it as inlined frames
# (from the IR's line information). Tools (and GPUCompiler's error messages) read
# backtraces from them. There is no information about variables or types.

# the emission kinds of `debug_info` (`DICompileUnit::DebugEmissionKind`)
const DEBUG_EMISSION_KINDS = (none=0, full=1, line_tables=2, directives=3)

"""
    JuliaCodegen.DebugInfo

The debug information of a module: its `DIBuilder`, the compile unit (of the file
`julia`, as native code's) and the files and subprograms created.
"""
mutable struct DebugInfo
    builder::LLVM.DIBuilder
    cu::LLVM.DICompileUnit
    files::Dict{String,LLVM.DIFile}
    "The subprograms of inlined functions, by name and file."
    inlined::Dict{Tuple{String,String},LLVM.DISubprogram}
    subroutine::LLVM.DISubroutineType
    finalized::Bool
end

function DebugInfo(mod::LLVM.Module, config::CodegenConfig)
    flags = mod.flags
    haskey(flags, "Debug Info Version") ||
        (flags["Debug Info Version", LLVM.ModuleFlagBehavior.Warning] =
             LLVM.Metadata(LLVM.ConstantInt(Int32(LLVM.DEBUG_METADATA_VERSION()))))
    haskey(flags, "Dwarf Version") ||
        (flags["Dwarf Version", LLVM.ModuleFlagBehavior.Warning] =
             LLVM.Metadata(LLVM.ConstantInt(Int32(4))))
    dib = LLVM.DIBuilder(mod)
    file = LLVM.file!(dib, "julia", ".")
    kind = reinterpret(LLVM.API.LLVMDWARFEmissionKind,
                       UInt32(DEBUG_EMISSION_KINDS[config.debug_info]))
    cu = LLVM.compile_unit!(dib, LLVM.API.LLVMDWARFSourceLanguageJulia, file, "julia";
                            optimized=true, emission_kind=kind)
    subroutine = LLVM.subroutine_type!(dib, file, nothing)
    return DebugInfo(dib, cu, Dict("julia" => file), Dict{Tuple{String,String},LLVM.DISubprogram}(),
                     subroutine, false)
end

# the debug information of the module of `cgm`, `nothing` without it
function debuginfo(cgm::CGModule)
    cgm.config.debug_info === :none && return nothing
    if cgm.debuginfo === nothing
        cgm.debuginfo = DebugInfo(cgm.mod, cgm.config)
    end
    return cgm.debuginfo
end

"Finish the debug information of the module of `cgm`, before it is used."
function finalize_debuginfo!(cgm::CGModule)
    di = cgm.debuginfo
    (di === nothing || di.finalized) && return
    LLVM.finalize!(di.builder)
    LLVM.dispose(di.builder)
    di.finalized = true
end

function difile(di::DebugInfo, file)
    name = string(file)
    get!(() -> LLVM.file!(di.builder, name, "."), di.files, name)
end

function subprogram!(di::DebugInfo, name::AbstractString, file, line::Integer,
                     linkage_name::AbstractString="")
    f = difile(di, file)
    return LLVM.subprogram!(di.builder, f, name, f, max(Int(line), 0), di.subroutine;
                            linkage_name, optimized=true)
end

# the name and file of a frame of the IR's line information
frame_name(@nospecialize(m)) =
    m isa Core.MethodInstance ? frame_name(m.def) :
    m isa Method ? String(m.name) :
    m isa Module ? "top-level scope" : string(m)

"""
    JuliaCodegen.debug_function!(fc, f; name, file, line)

Give the function `f` that `fc` emits a subprogram (`name` at `file:line`, by default
those of the method being compiled), and the builder its location, for the instructions
emitted before the first statement and in functions without IR (entries, stubs).
"""
function debug_function!(fc::FnCtx, f::LLVM.Function; name=nothing, file=nothing, line=nothing)
    di = debuginfo(fc.cgm)
    di === nothing && return nothing
    m = fc.info.mi.def
    name = something(name, frame_name(m))
    file = something(file, m isa Method ? m.file : :none)
    line = something(line, m isa Method ? m.line : 0)
    sp = subprogram!(di, name, file, line, LLVM.name(f))
    f.subprogram = sp
    fc.subprogram = sp
    LLVM.debug_location!(fc.builder, LLVM.DILocation(max(Int(line), 0), 0, sp))
    return sp
end

# the location of the statement `idx` of the IR: its line in the function, inlined into
# which the lines of the functions inlined at it
function statement_location!(fc::FnCtx, idx::Int)
    di = debuginfo(fc.cgm)
    (di === nothing || fc.subprogram === nothing) && return
    frames = Base.IRShow.buildLineInfoNode(fc.ir.debuginfo, fc.info.mi, idx)
    isempty(frames) && return    # (keep the previous location)
    loc = nothing
    for (k, fr) in enumerate(frames)
        scope = if k == 1
            fc.subprogram
        else
            name = frame_name(fr.method)
            get!(di.inlined, (name, string(fr.file))) do
                subprogram!(di, name, fr.file, 0)
            end
        end
        loc = LLVM.DILocation(max(Int(fr.line), 0), 0, scope, loc)
    end
    LLVM.debug_location!(fc.builder, loc)
end
