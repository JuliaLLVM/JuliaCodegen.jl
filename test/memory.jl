# Memory and arrays, through the JIT.

m_get(v, i) = v[i]
m_set!(v, i, x) = (v[i] = x; v)
m_sum(v) = (s = zero(eltype(v)); for x in v; s += x; end; s)
m_inbounds_sum(v) = (s = zero(eltype(v)); @inbounds for i in eachindex(v); s += v[i]; end; s)
m_axpy!(a, x, y) = (@inbounds for i in eachindex(x, y); y[i] += a * x[i]; end; y)
m_count_nothing(v) = (n = 0; for x in v; x === nothing && (n += 1); end; n)
m_memory(n) = Memory{Int}(undef, n)
m_memory_fill(n) = (m = Memory{Float64}(undef, n); for i in 1:n; m[i] = i; end; m)
m_length(m) = length(m)
m_sizeof(m) = sizeof(m)
m_isassigned(v, i) = isassigned(v, i)
# (arrays with unassigned elements, which the harness can't copy)
m_undef_get(n) = (v = Vector{String}(undef, n); v[1])
m_undef_isassigned(n) = (v = Vector{String}(undef, n); (isassigned(v, 1), (v[1] = "x"; isassigned(v, 1))))
m_undef_set(n) = (v = Vector{String}(undef, n); v[1] = "set"; v[1])
m_undef_pair(n) = (v = Vector{Pair{String,Int}}(undef, n); v[1])
function m_find(v::Vector{Int}, x::Int)
    for (i, y) in enumerate(v)
        y == x && return i
    end
    return nothing
end
function m_sum_found(v::Vector{Int})
    s = 0
    for x in v
        r = m_find(v, x)
        s += r === nothing ? 0 : r
    end
    return s
end

@testset "memory" begin

@testset "elements: $(eltype(v))" for (v, x) in Any[
        ([1.0, 2.0, 3.0], 9.5), ([1, 2, 3], 7), (Int8[1, 2, 3], Int8(9)),
        (Any[1, "a", :b], "x"), (["a", "b", "c"], "z"),
        ([1 => "a", 2 => "b", 3 => "c"], 9 => "z"),
        (Union{Nothing,Int}[1, nothing, 3], nothing), (Union{Nothing,Int}[1, nothing, 3], 5),
        (Union{Int8,Float32,Nothing}[Int8(1), 2.5f0, nothing], Int8(4)), ([(1, 2.0), (3, 4.0)], (9, 9.0))]
    for i in (1, 2, length(v), 0, length(v) + 1)
        @cgtest m_get(v, i)
        @cgtest m_set!(v, i, x)
    end
end

@testset "unassigned elements" begin
    @cgtest m_undef_get(2)                      # UndefRefError
    @cgtest m_undef_isassigned(2)
    @cgtest m_undef_set(2)
    @cgtest m_undef_pair(2)                     # UndefRefError
end

@testset "loops" begin
    for v in Any[collect(1:100), rand(50), Float32[1, 2, 3], Int[]]
        @cgtest m_sum(v)
        @cgtest m_inbounds_sum(v)
    end
    @cgtest m_axpy!(2.0, rand(20), rand(20))
    @cgtest m_count_nothing(Union{Nothing,Int}[1, nothing, nothing, 4])
    @cgtest m_sum_found(collect(1:30))
end

@testset "Memory" begin
    @test length(cgrun(m_memory, 5)) == 5
    @cgtest m_memory_fill(7)
    @cgtest m_length(Memory{Int}(undef, 3))
    @cgtest m_sizeof(Memory{Int}(undef, 3))
    @cgtest m_sizeof(Memory{Union{Nothing,Int8}}(undef, 3))
end

@testset "GC" begin
    # references stored into an old array survive collections (the write barrier)
    old = Vector{Any}(undef, 100)
    GC.gc(); GC.gc()
    for i in 1:100
        cgrun(m_set!, old, i, string(i))
        i % 25 == 0 && GC.gc(false)
    end
    GC.gc()
    @test all(i -> old[i] == string(i), 1:100)
end

@testset "code" begin
    # array loops make no dynamic calls (the error paths of bounds checks call the
    # runtime), and a union-returning callee in a loop doesn't allocate
    for (f, types) in ((m_sum, (Vector{Float64},)), (m_inbounds_sum, (Vector{Int},)),
                       (m_axpy!, (Float64, Vector{Float64}, Vector{Float64})),
                       (m_sum_found, (Vector{Int},)))
        @test @filecheck begin
            @check_not "@ijl_apply_generic"
            print(test_ir(f, types))
        end
    end
    # (compared with a call that does no work, for what `cgrun` itself allocates)
    v = collect(1:100)
    cgrun(m_sum_found, v), cgrun(m_length, v)
    # (the least of a few measurements: a GC or another task may allocate meanwhile)
    work = minimum(_ -> @allocated(cgrun(m_sum_found, v)), 1:10)
    baseline = minimum(_ -> @allocated(cgrun(m_length, v)), 1:10)
    @test work - baseline <= 64
    # element accesses are tied to their memory
    @test @filecheck begin
        @check "call ptr addrspace(13) @julia.gc_loaded("
        print(test_ir(m_get, (Vector{Float64}, Int)))
    end
end

end
