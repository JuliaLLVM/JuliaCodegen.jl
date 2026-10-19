# The task-local state every Julia function starts with: the pgcstack, the current task
# and its thread-local state, and the safepoint poll on entry. The sequences are the
# native code generator's (`emit_pgcstack`, `get_current_task`, `get_current_ptls` and
# `emit_gc_safepoint` in `src/llvm-codegen-shared.h`), with the offsets of the running
# Julia's runtime, so that Julia's passes lower them like native code.

i32(x) = LLVM.ConstantInt(LLVM.Int32Type(), x)

"""
    JuliaCodegen.get_pgcstack!(b, mod, dialect) -> LLVM.Value

The pgcstack, from a call of `julia.get_pgcstack`. Functions with a `"gcstack"` argument
(`dialect.gc_stack_argument`) use that instead.
"""
get_pgcstack!(b::LLVM.IRBuilder, mod::LLVM.Module, dialect::JuliaIR.Dialect) =
    call_op!(b, mod, dialect, "julia.get_pgcstack"; name="pgcstack")

"""
    JuliaCodegen.current_task!(b, rt::RuntimeFacts, pgcstack) -> LLVM.Value

The current task, at a fixed offset before its pgcstack.
"""
current_task!(b::LLVM.IRBuilder, rt::RuntimeFacts, pgcstack::LLVM.Value) =
    LLVM.inbounds_gep!(b, LLVM.Int8Type(), pgcstack, [i32(-rt.task_gcstack)], "current_task")

"""
    JuliaCodegen.current_ptls!(b, config, tbaa, task) -> LLVM.Value

The thread-local state of the current `task`.
"""
function current_ptls!(b::LLVM.IRBuilder, config::CodegenConfig, tbaa::TBAA, task::LLVM.Value)
    field = LLVM.inbounds_gep!(b, LLVM.Int8Type(), task, [i32(config.runtime.task_ptls)],
                               "ptls_field")
    ptls = LLVM.load!(b, T_ptr(), field, "ptls_load"; align=config.target.pointer_size)
    return tbaa!(tbaa, ptls, :gcframe)
end

"""
    JuliaCodegen.safepoint_poll!(b, mod, config, tbaa, ptls)

A GC safepoint: a `julia.safepoint` on the safepoint page of the thread-local state
`ptls`, between compiler fences, which FinalLowerGC lowers to a load from the page.
"""
function safepoint_poll!(b::LLVM.IRBuilder, mod::LLVM.Module, config::CodegenConfig,
                         tbaa::TBAA, ptls::LLVM.Value)
    dialect = config.dialect
    style = dialect.gc_safepoint_load
    addr = LLVM.inbounds_gep!(b, LLVM.Int8Type(), ptls, [i32(config.runtime.tls_safepoint)],
                              style === :monotonic_named ? "safepoint_addr" : "")
    ordering = style === :plain ? LLVM.API.LLVMAtomicOrderingNotAtomic :
                                  LLVM.API.LLVMAtomicOrderingMonotonic
    page = LLVM.load!(b, T_ptr(), addr, "safepoint"; ordering,
                      align=config.target.pointer_size)
    tbaa!(tbaa, page, :const)
    page.metadata[LLVM.MD_invariant_load] = LLVM.MDNode(LLVM.Metadata[])
    LLVM.fence!(b, LLVM.API.LLVMAtomicOrderingSequentiallyConsistent, true)
    call_op!(b, mod, dialect, "julia.safepoint", page)
    LLVM.fence!(b, LLVM.API.LLVMAtomicOrderingSequentiallyConsistent, true)
    return nothing
end
