# Tests of the test helpers themselves.

@testset "harness" begin

@testset "differential" begin
    native(f, args...) = f(args...)
    @test differential(native, +, 1, 2) == OK
    @test differential(native, /, 0.0, 0.0) == OK                      # isequal(NaN, NaN)
    @test differential(native, sqrt, -1.0) == OK                       # both throw DomainError

    @test differential((f, args...) -> 4, +, 1, 2) == Outcome(:value, 3, 4)
    @test differential((f, args...) -> 3.0, +, 1, 2) == Outcome(:type, 3, 3.0)
    o = differential((f, args...) -> error("no"), +, 1, 2)
    @test o.kind === :exception && o.expected == 3 && o.got isa ErrorException
    o = differential((f, args...) -> throw(ArgumentError("")), sqrt, -1.0)
    @test o.kind === :exception && o.expected isa DomainError && o.got isa ArgumentError

    # every execution gets its own copy of the arguments, and mutation is compared
    v = [1, 2]
    @test differential(native, push!, v, 3) == OK
    @test v == [1, 2]
    o = differential((f, x, y) -> (push!(x, y); push!(x, y)), push!, [1], 2)
    @test o.kind === :value
    o = differential((f, x, y) -> (x[1] = 0; nothing), (x, y) -> nothing, [1], 2)
    @test o == Outcome(:arguments, ([1], 2), ([0], 2))

    @test differential(native, +, 1, 2; gc=true) == OK

    # mutable objects without `==` compare by their fields
    @test results_equal(Ref(1), Ref(1))
    @test !results_equal(Ref(1), Ref(2))
    @test results_equal((Ref(1), 2), (Ref(1), 2))
    @test !results_equal(Ref{Any}(1), Ref{Int}(1))
    @test sprint(show, OK) == "Outcome(:ok)"
    @test sprint(show, Outcome(:value, 3, 4)) == "Outcome(:value, expected = 3::Int64, got = 4::Int64)"
end

@testset "@cgtest" begin
    native(f, args...) = f(args...)
    @cgtest run=native +(1, 2)
    @cgtest run=native sum([1.0, 2.0])
    @test_throws LoadError @eval @cgtest 1
    @test_throws LoadError @eval @cgtest foo=1 f(1)
    @test_throws LoadError @eval @cgtest f(args...)
end

@testset "verify_ir" begin
    good = """
        declare void @use(ptr addrspace(10))
        define ptr addrspace(10) @f(ptr addrspace(10) %obj) {
          call void @use(ptr addrspace(10) %obj)
          ret ptr addrspace(10) %obj
        }"""
    bad = """
        define ptr addrspace(11) @f(ptr addrspace(10) %obj) {
          %derived = addrspacecast ptr addrspace(10) %obj to ptr addrspace(11)
          ret ptr addrspace(11) %derived
        }"""
    @dispose ctx=Context(; opaque_pointers=true) begin
        @dispose mod=parse(LLVM.Module, good) begin
            @test verify_ir(mod; dialect=false) === mod
        end
        @dispose mod=parse(LLVM.Module, bad) begin
            @test @filecheck throws=PassException begin
                @check "GCInvariantError: GC invariants are violated in function f"
                @check_next "Only gc tracked values may be directly returned"
                @check_next "ret ptr addrspace(11) %derived"
                verify_ir(mod; dialect=false)
            end
        end
    end
end

end
