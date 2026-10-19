# Facts about the running Julia that generated code depends on: the conventions of its
# LLVM IR (`JuliaIR.Dialect`) and its runtime's layouts and ABI (`RuntimeFacts`). Both come
# from JuliaIR.jl, whose passes process the same IR, so the code generator and the passes
# agree on them.

"""
    JuliaCodegen.RuntimeFacts

The facts about the running Julia's runtime that generated code depends on, from
`JuliaIR.runtime_layout` (see JuliaIR.jl's documentation for where each comes from):

- `task_gcstack`, `task_ptls`, `task_eh`: byte offsets in `jl_task_t` (the current task is
  the pgcstack minus `task_gcstack`);
- `tls_safepoint`: the offset of the safepoint page's address in `jl_tls_states_t`;
- `handler_size`, `handler_align`: of an exception handler (`jl_handler_t`);
- `setjmp`: the name of the runtime's setjmp;
- `smalltag_shift`, `max_small_tag`: objects of builtin types carry `smalltag << 4` in
  their header instead of the address of their type; a `DataType`'s tag is
  `flags >> smalltag_shift`, and tags are below `max_small_tag`;
- `task_world_age`: the offset of the world age in `jl_task_t`;
- `cfunction_cache`, `cfuncdata_size`: the call-site data of a `@cfunction` that
  `jl_get_abi_converter` resolves its entry point with (`cfuncdata_t`, of
  `cfuncdata_size` bytes), and where the entry point and the world it is valid in are
  cached: in separate words passed with it (`:arguments`, Julia 1.12), or in its first
  two fields (`:cfuncdata`).
"""
struct RuntimeFacts
    task_gcstack::Int
    task_ptls::Int
    task_eh::Int
    tls_safepoint::Int
    handler_size::Int
    handler_align::Int
    setjmp::String
    smalltag_shift::Int
    max_small_tag::Int
    task_world_age::Int
    cfunction_cache::Symbol
    cfuncdata_size::Int
end

"""
    JuliaCodegen.runtime_facts() -> RuntimeFacts

The facts about the running Julia's runtime. JuliaIR.jl reads them from the runtime and
from code that Julia's code generator emits, once per process: this happens when the
first [`CodegenConfig`](@ref JuliaCodegen.CodegenConfig) is created, never while code is
being generated (which may run inside Julia's compiler).
"""
runtime_facts() = RUNTIME_FACTS()

const RUNTIME_FACTS = OncePerProcess{RuntimeFacts}() do
    dialect = JuliaIR.Dialect(VERSION)
    @dispose ctx=LLVM.Context() mod=LLVM.Module("runtime facts") begin
        rt = JuliaIR.runtime_layout(dialect, mod)
        RuntimeFacts(rt.task_gcstack, rt.task_ptls, rt.task_eh, rt.tls_safepoint,
                     rt.handler_size, rt.handler_align, rt.setjmp, rt.smalltag_shift,
                     rt.max_small_tag, rt.task_world_age, rt.cfunction_cache,
                     rt.cfuncdata_size)
    end
end

"""
    JuliaCodegen.setjmp_savemask(target::Target) -> Bool

Whether the runtime's setjmp on `target` takes a `savemask` argument (`sigsetjmp`): not on
Windows, where it is Julia's own. Like the C++ code generator, this follows the target
triple.
"""
setjmp_savemask(target::Target) = platform(target.triple).os !== :windows

# The operating system and architecture of a target triple.
function platform(triple::AbstractString)
    parts = split(lowercase(triple), '-')
    rest = join(parts[2:end], '-')
    arch = parts[1] in ("x86_64", "amd64") ? :x86_64 :
           parts[1] in ("aarch64", "arm64") ? :aarch64 :
           occursin(r"^i[3-6]86$", parts[1]) ? :i686 : Symbol(parts[1])
    os = occursin(r"windows|mingw|win32|cygwin", rest) ? :windows :
         occursin(r"darwin|macos|apple", rest) ? :darwin :
         occursin("linux", rest) ? :linux :
         occursin("freebsd", rest) ? :freebsd : :unknown
    return (; arch, os)
end
