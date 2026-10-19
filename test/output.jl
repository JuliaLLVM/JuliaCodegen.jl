# What a compilation produces: entries, objects, symbols; relocatability; pipelines.

o_greet(x) = string("hello ", x)
o_add(x, y) = x + y
o_type(x) = typeof(x) === Int
o_pointer() = unsafe_load(Ptr{Int}(0x7f0012345678))

function o_compile(f, types; pipeline=JuliaCodegen.NoPipeline(), specsig=false)
    @dispose ctx=LLVM.Context() mod=LLVM.Module("jcoutput") begin
        config = test_config()
        cgm = JuliaCodegen.CGModule(mod, config)
        info, _ = JuliaCodegen.emit_entry!(cgm, Tuple{Core.Typeof(f), types...}; name="o_entry")
        specsig && JuliaCodegen.emit_specsig_wrapper!(cgm, info, "o_entry_specsig")
        out = JuliaCodegen.codegen_output(cgm)
        problems = JuliaCodegen.check_relocatable(mod, config)
        JuliaCodegen.run_pipeline!(pipeline, mod, config)
        return (; out, problems, ir=string(mod))
    end
end

@testset "output" begin

@testset "entries, objects and symbols" begin
    r = o_compile(o_greet, (Int,); specsig=true)
    @test [(e.name, e.abi) for e in r.out.entries] == [("o_entry", :jlcall), ("o_entry_specsig", :specsig)]
    @test all(e -> e.mi.def.name === :o_greet, r.out.entries)
    @test issorted(first.(r.out.literals))
    @test any(((name, x),) -> x === "hello ", r.out.literals)
    @test all(s -> !startswith(s, "julia.") && !startswith(s, "llvm."), r.out.symbols)
    @test "ijl_apply_generic" in r.out.symbols || "ijl_invoke" in r.out.symbols
    @test isempty(r.problems)
end

@testset "relocatable" begin
    # small type tags are not addresses
    @test isempty(o_compile(o_type, (Any,)).problems)
    # a pointer known at compile time is
    problems = o_compile(o_pointer, ()).problems
    @test length(problems) == 1 && occursin("139638282147448", only(problems))
end

@testset "deterministic" begin
    @test o_compile(o_greet, (Int,)).ir == o_compile(o_greet, (Int,)).ir
    @test o_compile(o_add, (Int, Float64)).out.literals == o_compile(o_add, (Int, Float64)).out.literals
end

@testset "pipelines" begin
    @test occursin("@julia.", o_compile(o_greet, (Int,)).ir)
    lowered = o_compile(o_greet, (Int,); pipeline=JuliaCodegen.JuliaCppPipeline()).ir
    @test !occursin(r"call [^\n]*@julia\.", lowered)
    @test !occursin("addrspace(10)", lowered)
    ran = Ref(false)
    custom = JuliaCodegen.CustomPipeline((mod, tm) -> (ran[] = mod isa LLVM.Module && tm isa LLVM.TargetMachine))
    o_compile(o_add, (Int, Int); pipeline=custom)
    @test ran[]
end

end
