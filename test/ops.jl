using LLVM.Build

@testset "intrinsics" begin

JC = JuliaCodegen
config = JC.CodegenConfig()
dialect = config.dialect
irs = native_probe_modules()

attribute_set(attrs) = sort!([string(a) for a in collect(attrs)])
declaration(f::LLVM.Function) =
    (; type=string(f.function_type), fn=attribute_set(f.function_attributes),
       ret=attribute_set(f.return_attributes),
       params=[attribute_set(p) for p in f.parameter_attributes])

# every intrinsic that native code declares, as JuliaCodegen declares it
@testset "declarations" begin
    native = Dict{String,Any}()
    @dispose ctx=Context() begin
        for ir in irs
            @dispose mod=parse(LLVM.Module, ir) begin
                for f in mod.functions
                    occursin(r"^(llvm\.)?julia\.", f.name) && isdeclaration(f) || continue
                    native[f.name] = declaration(f)
                end
            end
        end
        @dispose mod=LLVM.Module("ours") begin
            for (name, decl) in native
                @testset "$name" begin
                    @test declaration(JC.declare_op(mod, dialect, name)) == decl
                end
            end
        end
    end
    # the probes cover the intrinsics of the dialect
    expected = ["julia.get_pgcstack", "julia.gc_alloc_obj", "julia.call", "julia.typeof",
                "julia.gc_loaded", "julia.pointer_from_objref", "julia.safepoint",
                "llvm.julia.gc_preserve_begin", "llvm.julia.gc_preserve_end"]
    dialect.except_enter === :task_buffer && push!(expected, "julia.except_enter")
    dialect.barrier_flavour === :write_barrier ? push!(expected, "julia.write_barrier") :
        append!(expected, ["julia.field_write_barrier.p11", "julia.field_write_barrier.p13"])
    @test issubset(expected, keys(native))

    # the runtime functions and globals, as native code declares them
    @dispose ctx=Context() begin
        for (name, f, tt) in [(:jl_apply_generic, (f, x) -> f(x), Tuple{Any,Any}),
                              (:jl_throw, x -> throw(x), Tuple{Any}),
                              (:jl_subtype, x -> x isa Integer, Tuple{Any}),
                              (:jl_egal__unboxed, (x, y) -> x === y, Tuple{Any,Any}),
                              (:jl_excstack_state, x -> try probe_throws(x) catch; 0 end, Tuple{Int}),
                              (:jl_pop_handler, x -> try probe_throws(x) catch; 0 end, Tuple{Int}),
                              (:jl_pop_handler_noexcept, x -> try probe_throws(x) catch; 0 end, Tuple{Int}),
                              (:jl_restore_excstack, x -> try probe_throws(x) catch; 0 end, Tuple{Int}),
                              (:jl_current_exception, x -> try probe_throws(x) catch e; e end, Tuple{Int})]
            @dispose nmod=parse(LLVM.Module, native_module_ir(f, tt)) mod=LLVM.Module("ours") begin
                nf = nmod.functions[JC.runtime_symbol(name)]
                @test declaration(JC.declare_runtime(mod, dialect, name)) == declaration(nf)
            end
        end
        @dispose nmod=parse(LLVM.Module, native_module_ir(x -> typeof(x), Tuple{Any})) mod=LLVM.Module("ours") begin
            ng = LLVM.globals(nmod)["jl_small_typeof"]
            g = JC.runtime_global(mod, :jl_small_typeof, LLVM.Int8Type())
            @test g.global_value_type == ng.global_value_type
            @test g.constant == ng.constant
        end
    end

    @dispose ctx=Context() mod=LLVM.Module("ours") begin
        f = JC.declare_op(mod, dialect, "julia.typeof")
        @test JC.declare_op(mod, dialect, "julia.typeof") === f
        @test_throws "julia.unknown is not an intrinsic of" JC.declare_op(mod, dialect, "julia.unknown")
        if dialect.except_enter !== :task_buffer
            @test_throws "is not an intrinsic" JC.declare_op(mod, dialect, "julia.except_enter")
        end
    end
end

# the TBAA type nodes of native code are those of JuliaCodegen's tree
@testset "TBAA" begin
    native = Dict{String,String}()
    for ir in irs
        md = Dict(m[1] => m[2] for m in eachmatch(r"^(!\d+) = (?:distinct )?(!\{.*\})$"m, ir))
        for v in values(md)
            m = match(r"^!\{!\"(jtbaa\w*)\", (!\d+), i64 0\}$", v)
            m === nothing && continue
            p = match(r"^!\{!\"(jtbaa\w*)\"", md[m[2]])
            native[m[1]] = p[1]
        end
    end
    @test native["jtbaa"] == "jtbaa"   # the root
    tree = JC.tbaa_tree(dialect)
    for (name, parent) in native
        name == "jtbaa" && continue
        kind = Symbol(chopprefix(name, "jtbaa_"))
        @test haskey(tree, kind)
        @test (tree[kind] === :root ? "jtbaa" : "jtbaa_$(tree[kind])") == parent
    end

    # access tags: of constant memory, and of an object field, as native code has them
    @dispose ctx=Context() mod=LLVM.Module("ours") b=IRBuilder() begin
        t = JC.TBAA(dialect)
        field = dialect.minor >= v"1.14" ? :field : :mutab
        f = LLVM.Function(mod, "f", LLVM.FunctionType(LLVM.VoidType(), [JC.T_ptr()]))
        position!(b, LLVM.at_end(BasicBlock(f, "top")))
        JC.tbaa!(t, load!(b, JC.T_ptr(), LLVM.parameters(f)[1]), :const)
        JC.tbaa!(t, load!(b, JC.T_ptr(), LLVM.parameters(f)[1]), field)
        ret!(b)
        @test @filecheck begin
            @check "load ptr, ptr %0, align 8, !tbaa ![[CONST:[0-9]+]]"
            @check "load ptr, ptr %0, align 8, !tbaa ![[FIELD:[0-9]+]]"
            @check "![[CONST]] = !{![[CNODE:[0-9]+]], ![[CNODE]], i64 0, i64 1}"
            @check "![[CNODE]] = !{!\"jtbaa_const\", ![[ROOT:[0-9]+]], i64 0}"
            @check "![[ROOT]] = !{!\"jtbaa\", ![[ROOTNAME:[0-9]+]], i64 0}"
            @check "![[ROOTNAME]] = !{!\"jtbaa\"}"
            @check "![[FIELD]] = !{![[FNODE:[0-9]+]], ![[FNODE]], i64 0}"
            @check "![[FNODE]] = !{!\"jtbaa_$(field)\", ![[VALUE:[0-9]+]], i64 0}"
            @check "![[VALUE]] = !{!\"jtbaa_value\", ![[DATA:[0-9]+]], i64 0}"
            @check "![[DATA]] = !{!\"jtbaa_data\", ![[ROOT]], i64 0}"
            print(string(mod))
        end
        @test JC.tbaa_tag(t, :gcframe) === JC.tbaa_tag(t, :gcframe)
        @test_throws "no TBAA node jtbaa_nothing" JC.tbaa_tag(t, :nothing)
    end
end

# the prologue: the instructions native code starts a function with, up to the safepoint
function prologue_lines(ir)
    lines = split(ir, '\n')
    first = findfirst(==("top:"), lines) + 1
    last = findall(l -> occursin("fence syncscope(\"singlethread\")", l), lines)[2]
    map(filter(l -> !occursin(r"llvm\.dbg|#dbg_", l), lines[first:last])) do l
        l = replace(l, r", !dbg !\d+" => "", r"!(tbaa|invariant\.load) !\d+" => s"!\1",
                    r"%(\w+?)\d*\b" => s"%\1", "%pgcstack_arg" => "%pgcstack")
        strip(l)
    end
end

@testset "prologue" begin
    native = prologue_lines(native_module_ir((x::Int) -> Ref(x), Tuple{Int}))
    @dispose ctx=Context() mod=LLVM.Module("ours") b=IRBuilder() begin
        tbaa = JC.TBAA(dialect)
        params = dialect.gc_stack_argument ? LLVM.LLVMType[JC.T_ptr()] : LLVM.LLVMType[]
        f = LLVM.Function(mod, "f", LLVM.FunctionType(LLVM.VoidType(), params))
        position!(b, LLVM.at_end(BasicBlock(f, "top")))
        pgcstack = if dialect.gc_stack_argument
            LLVM.name!(LLVM.parameters(f)[1], "pgcstack_arg")
            LLVM.parameters(f)[1]
        else
            JC.get_pgcstack!(b, mod, dialect)
        end
        task = JC.current_task!(b, config.runtime, pgcstack)
        JC.safepoint_poll!(b, mod, config, tbaa, JC.current_ptls!(b, config, tbaa, task))
        ret!(b)
        @test prologue_lines(string(mod)) == native
        @test verify_ir(mod) === mod
    end
end

@testset "write barriers" begin
    @dispose ctx=Context() mod=LLVM.Module("ours") b=IRBuilder() begin
        T = JC.T_tracked()
        f = LLVM.Function(mod, "f", LLVM.FunctionType(LLVM.VoidType(), [T, T]))
        parent, value = LLVM.parameters(f)
        LLVM.name!(parent, "parent")
        LLVM.name!(value, "value")
        position!(b, LLVM.at_end(BasicBlock(f, "top")))
        field = addrspacecast!(b, parent, JC.T_derived(), "field")
        JC.write_barrier!(b, mod, dialect, parent, field, value)
        ret!(b)
        object = dialect.barrier_flavour === :write_barrier
        @test @filecheck begin
            @check cond=object "call void (ptr addrspace(10), ...) @julia.write_barrier(ptr addrspace(10) %parent, ptr addrspace(10) %value)"
            @check cond=!object "call void (ptr addrspace(10), ptr addrspace(11), ptr addrspace(10), ...) @julia.field_write_barrier.p11(ptr addrspace(10) %parent, ptr addrspace(11) %field, ptr addrspace(10) %value)"
            print(string(mod))
        end
        @test verify_ir(mod) === mod
    end
end

end
