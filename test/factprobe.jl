# Recover the facts of `src/facts.jl` from the IR of Julia's own code generator, for the
# running Julia on its host. Only the tests do this: JuliaCodegen itself never inspects
# native code. Running this file prints the facts, e.g. to add a platform to the tables.

using InteractiveUtils

@noinline _probe_mayfail(x) = x > 0 ? x : error("negative")
_probe_try(x) = try _probe_mayfail(x) catch; -1 end
_probe_alloc(x::Int) = Ref(x)
_probe_store(r::Base.RefValue{Any}, x) = (r[] = x; nothing)

native_ir(f, tt) = sprint(io -> code_llvm(io, f, tt; raw=true, optimize=false,
                                          debuginfo=:none, dump_module=false))

function capture(re::Regex, str::AbstractString, what)
    m = match(re, str)
    m === nothing && error("could not find $what in native IR:\n$str")
    return m
end

const GEP_OFFSET = raw"getelementptr inbounds i8, ptr %(?:PTR)\w*, i(?:32|64) (-?\d+)"
gep_regex(lhs, ptr) = Regex("%$lhs\\w* = " * replace(GEP_OFFSET, "(?:PTR)" => ptr))

"""
    probe_facts() -> NamedTuple

The facts of the running Julia, recovered from native IR and from object headers.
"""
function probe_facts()
    ir = native_ir(_probe_alloc, Tuple{Int})
    gcstack = -parse(Int, capture(gep_regex("current_task", "pgcstack"), ir, "the current task")[1])
    ptls = parse(Int, capture(gep_regex("ptls_field", "current_task"), ir, "the ptls field")[1])
    safepoint = parse(Int, capture(Regex(replace(GEP_OFFSET, "(?:PTR)" => "ptls_load")), ir,
                                   "the safepoint field")[1])
    gcstack_argument = occursin("\"gcstack\" %pgcstack_arg", ir)

    tir = native_ir(_probe_try, Tuple{Int})
    exceptions = occursin("@julia.except_enter", tir) ? :except_enter : :setjmp
    eh = parse(Int, capture(r"getelementptr inbounds i8, ptr %current_task\w*, i(?:32|64) (\d+)[^\n]*\n\s*store ptr",
                            tir, "the store of the exception handler")[1])
    handler_size = handler_align = 0
    setjmp_name = ""
    setjmp_savemask = false
    if exceptions === :setjmp
        h = capture(r"call void @i?jl_enter_handler\(ptr %[\w.]+, ptr (%[\w.]+)\)", tir,
                    "the call of jl_enter_handler")[1]
        a = capture(Regex("\\Q$h\\E = alloca \\[(\\d+) x i(\\d+)\\], align (\\d+)"), tir,
                    "the handler's alloca")
        handler_size = parse(Int, a[1]) * parse(Int, a[2]) ÷ 8
        handler_align = parse(Int, a[3])
        s = capture(Regex("call i32 @([\\w.]+)\\(ptr \\Q$h\\E(, i32 0)?\\)"), tir,
                    "the call of setjmp")
        setjmp_name = s[1]
        setjmp_savemask = s[2] !== nothing
    end

    bir = native_ir(_probe_store, Tuple{Base.RefValue{Any}, Any})
    barrier_flavour = occursin("@julia.write_barrier", bir) ? :write_barrier : :object_field

    # objects of types with a small tag carry `smalltag << 4` in their header
    box = Any[Int64(1)]
    header = GC.@preserve box begin
        obj = unsafe_load(Ptr{Ptr{UInt}}(pointer(box)))
        unsafe_load(obj - sizeof(UInt))
    end
    int64_tag = Int((header & ~UInt(15)) >> 4)
    smalltag_shift = something(findfirst(s -> Int(Int64.flags >> s) == int64_tag, 0:31)) - 1

    return (; task_gcstack_offset=gcstack, task_ptls_offset=ptls,
            ptls_safepoint_offset=safepoint, task_eh_offset=eh, handler_size,
            handler_align, setjmp_name, setjmp_savemask, smalltag_shift, int64_tag,
            exceptions, gcstack_argument, barrier_flavour)
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("Julia ", VERSION, " on ", Sys.MACHINE)
    foreach(((k, v),) -> println("  ", k, " = ", repr(v)), pairs(probe_facts()))
end
