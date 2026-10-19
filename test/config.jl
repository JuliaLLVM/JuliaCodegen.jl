@testset "configuration" begin

JC = JuliaCodegen

@testset "C ABI of a triple" begin
    @test JC.c_abi_kind("x86_64-unknown-linux-gnu") === :x86_64
    @test JC.c_abi_kind("x86_64-w64-windows-gnu") === :win64
    @test JC.c_abi_kind("x86_64-pc-windows-msvc") === :win64
    @test JC.c_abi_kind("i686-linux-gnu") === :x86
    @test JC.c_abi_kind("i686-w64-mingw32") === :win32
    @test JC.c_abi_kind("aarch64-linux-gnu") === :aarch64
    @test JC.c_abi_kind("arm64-apple-darwin") === :aarch64
    @test JC.c_abi_kind("armv7-linux-gnueabihf") === :arm
    @test JC.c_abi_kind("riscv64-linux-gnu") === :riscv64
    @test JC.c_abi_kind("powerpc64le-linux-gnu") === :ppc64le
    @test JC.c_abi_kind("wasm32-unknown-unknown") === :llvm
    # "win" in the architecture is not Windows
    @test JC.c_abi_kind("x86_64-unknown-darwin") === :x86_64
end

@testset "Target" begin
    t = JC.Target(; triple="x86_64-linux-gnu")
    @test t.triple == "x86_64-unknown-linux-gnu"
    @test t.pointer_size == 8
    @test t.c_abi === :x86_64
    @test endswith(t.datalayout, "-ni:10:11:12:13")

    @test JC.Target(; triple="armv7-linux-gnueabihf").pointer_size == 4
    @test JC.Target(; triple="i686-linux-gnu").c_abi === :x86

    # an explicit data layout gets Julia's address spaces, once
    dl = "e-p:32:32-i64:64"
    @test JC.Target(; triple="x86_64-linux-gnu", datalayout=dl).datalayout == dl * "-ni:10:11:12:13"
    @test JC.Target(; triple="x86_64-linux-gnu", datalayout=dl * "-ni:10:11:12:13").pointer_size == 4

    # no back end and no known data layout
    @test_throws "no data layout is known" JC.Target(; triple="bogus-unknown-unknown")

    @test sprint(show, t) == "JuliaCodegen.Target(triple=\"x86_64-unknown-linux-gnu\")"

    host = JC.host_target()
    JC.target_machine(host) do tm
        @test LLVM.triple(tm) == host.triple
    end
    @test_throws "no back end" JC.target_machine(identity, JC.Target(; triple="bogus-unknown-unknown",
                                                           datalayout="e"))
end

@testset "host target" begin
    host = JC.host_target()
    @test host === JC.host_target()
    @test host.pointer_size == sizeof(Ptr{Cvoid})
    @test !isempty(host.cpu)
    # the data layout of the modules of Julia's code generator, before RemoveNI drops
    # the non-integral address spaces
    ir = sprint(io -> code_llvm(io, +, (Int, Int); raw=true, dump_module=true, optimize=false))
    @test host.datalayout == match(r"target datalayout = \"(.*)\"", ir)[1]
    @test host.triple == match(r"target triple = \"(.*)\"", ir)[1]
end

@testset "CodegenConfig" begin
    config = JC.CodegenConfig()
    @test config.target === JC.host_target()
    @test config.on_unsupported === :fallback
    @test config.on_internal_error === :fallback

    @test_throws "invalid on_unsupported policy :ignore" JC.CodegenConfig(; on_unsupported=:ignore)
    @test_throws "invalid on_internal_error policy" JC.CodegenConfig(; on_internal_error=:skip)
end

@testset "failure policies" begin
    fallback = JC.CodegenConfig()
    strict = JC.CodegenConfig(; on_unsupported=:error, on_internal_error=:error)
    bt = backtrace()

    err = JC.Unsupported("the builtin ", Core.svec, " with ", 3, " arguments")
    @test sprint(showerror, err) == "JuliaCodegen: unsupported: the builtin svec with 3 arguments"
    @test_throws JC.Unsupported JC.unsupported("x")
    @test JC.handle_failure(fallback, :f, err, bt) === :fallback
    @test_throws JC.Unsupported JC.handle_failure(strict, :f, err, bt)

    # internal errors are reported when falling back, and wrapped when not
    ierr = BoundsError([1], 2)
    @test (@test_logs (:error, "JuliaCodegen failed; falling back") JC.handle_failure(fallback, :g, ierr, bt)) === :fallback
    @test @filecheck throws=JC.InternalError begin
        @check "JuliaCodegen: internal error while compiling h: BoundsError"
        JC.handle_failure(strict, :h, ierr, bt)
    end
end

end
