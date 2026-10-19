# Debug information: line tables.

@noinline d_inner(x) = x * 2
d_outer(x) = d_inner(x) + sin(x)
d_entry(x) = d_outer(x)

const D_CONFIG = JuliaCodegen.CodegenConfig(; on_unsupported=:error, on_internal_error=:error,
                                           debug_info=:line_tables)
d_run(f, args...) = cgrun(f, args...; config=D_CONFIG)

function d_ir(f, types; config=D_CONFIG)
    @dispose ctx=LLVM.Context() mod=LLVM.Module("jcdebug") begin
        cgm = JuliaCodegen.CGModule(mod, config)
        JuliaCodegen.emit_entry!(cgm, Tuple{Core.Typeof(f), types...}; name="d_entry")
        JuliaCodegen.codegen_output(cgm)
        verify_ir(mod)
        return string(mod)
    end
end

@testset "debug info" begin

@testset "line tables" begin
    ir = d_ir(d_outer, (Float64,))
    @test @filecheck begin
        @check "define internal double @julia_d_outer_{{[0-9]+}}(double %0) #{{[0-9]+}} !dbg ![[SP:[0-9]+]]"
        @check "call double @julia_d_inner_{{[0-9]+}}(double %{{[0-9]+}}){{.*}}, !dbg ![[CALL:[0-9]+]]"
        @check "!llvm.dbg.cu = !{![[CU:[0-9]+]]}"
        @check "![[CU]] = distinct !DICompileUnit(language: DW_LANG_Julia, file: ![[FILE:[0-9]+]], producer: \"julia\", isOptimized: true, runtimeVersion: 0, emissionKind: LineTablesOnly"
        @check "![[FILE]] = !DIFile(filename: \"julia\", directory: \".\")"
        @check "![[SP]] = distinct !DISubprogram(name: \"d_outer\", linkageName: \"julia_d_outer_{{[0-9]+}}\""
        ir
    end
    # the lines of the functions inlined into a statement: inlined frames
    @test occursin(r"!DILocation\(line: \d+, scope: ![0-9]+, inlinedAt: ![0-9]+\)", ir)
    @test occursin("!DISubprogram(name: \"sin\"", ir) || occursin("!DISubprogram(name: \"+\"", ir)
    # the innermost location's column is the statement (as native code from Julia 1.14 on)
    @test occursin(r"!DILocation\(line: \d+, column: [1-9]\d*, scope: ", ir)
    # every function has a subprogram, entries included
    @test count("distinct !DISubprogram(name: \"d_outer\"", ir) == 2
    # without, none
    @test !occursin("!dbg", d_ir(d_outer, (Float64,); config=test_config()))
end

@testset "code with it" begin
    @cgtest run=d_run d_entry(0.5)
    @cgtest run=d_run d_outer(2.0)
end

@testset "emission kinds" begin
    for (kind, name) in ((:directives, "DebugDirectivesOnly"), (:full, "FullDebug"))
        config = JuliaCodegen.CodegenConfig(; on_unsupported=:error, on_internal_error=:error,
                                            debug_info=kind)
        @test occursin("emissionKind: $name", d_ir(d_inner, (Int,); config))
    end
    @test_throws "invalid debug_info" JuliaCodegen.CodegenConfig(; debug_info=:lines)
end

end
