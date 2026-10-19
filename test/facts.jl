@testset "facts" begin

JC = JuliaCodegen

@testset "configuration" begin
    config = JC.CodegenConfig()
    @test config.dialect == JuliaIR.Dialect(VERSION)
    @test config.runtime === JC.runtime_facts()

    # the dialect's policies
    d = JuliaIR.Dialect(VERSION; gc_barrier=:snapshot)
    @test JC.CodegenConfig(; dialect=d).dialect.gc_barrier === :snapshot

    # code is only generated for the running Julia
    other = JuliaIR.Dialect(VERSION.minor == 12 ? v"1.13" : v"1.12")
    @test_throws "is not the dialect of the running Julia" JC.CodegenConfig(; dialect=other)
end

@testset "platforms" begin
    @test JC.platform("x86_64-unknown-linux-gnu") == (; arch=:x86_64, os=:linux)
    @test JC.platform("arm64-apple-darwin23") == (; arch=:aarch64, os=:darwin)
    @test JC.platform("x86_64-w64-windows-gnu-elf") == (; arch=:x86_64, os=:windows)
    @test JC.platform("i686-w64-mingw32") == (; arch=:i686, os=:windows)
    @test JC.setjmp_savemask(JC.Target(; triple="x86_64-linux-gnu"))
    @test !JC.setjmp_savemask(JC.Target(; triple="x86_64-w64-windows-gnu"))
end

# The facts against the IR of Julia's own code generator, for the running Julia on this
# host: JuliaIR.jl reads them independently.
@testset "against native code" begin
    probed = probe_facts()
    config = JC.CodegenConfig()
    dialect = config.dialect
    rt = config.runtime

    # how `try` is emitted: by the code generator from 1.13 on, which doesn't emit
    # `julia.except_enter` any more
    @test (dialect.except_enter === :none) == (probed.exceptions === :setjmp)
    @test dialect.gc_stack_argument == probed.gcstack_argument
    @test dialect.barrier_flavour === probed.barrier_flavour

    @test rt.task_gcstack == probed.task_gcstack_offset
    @test rt.task_ptls == probed.task_ptls_offset
    @test rt.tls_safepoint == probed.ptls_safepoint_offset
    @test rt.task_eh == probed.task_eh_offset
    if probed.exceptions === :setjmp
        @test rt.handler_size == probed.handler_size
        @test rt.handler_align == probed.handler_align
        @test rt.setjmp == probed.setjmp_name
        @test JC.setjmp_savemask(config.target) == probed.setjmp_savemask
    end
    @test rt.smalltag_shift == probed.smalltag_shift
    @test probed.int64_tag < rt.max_small_tag
end

end
