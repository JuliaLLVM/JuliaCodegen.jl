# Modules of Julia's own code generator, for comparing what JuliaCodegen emits with what
# native code looks like for the running Julia.

using InteractiveUtils

"The unoptimized module that Julia's code generator emits for `f(::tt...)`."
native_module_ir(f, tt) = sprint(io -> code_llvm(io, f, tt; raw=true, optimize=false,
                                                 dump_module=true, debuginfo=:none))

mutable struct ProbeMutable; x::Any; y::Int; end
struct ProbeImmutable; x::Int; y::Float64; end
@noinline probe_throws(x) = x > 0 ? x : error("negative")

# Functions whose native code uses every intrinsic JuliaCodegen declares, and a variety
# of memory accesses.
const NATIVE_PROBES = [
    ((x::Int) -> Ref(x), Tuple{Int}),                                   # allocation
    ((f, x) -> f(x), Tuple{Any,Any}),                                   # dynamic call
    ((m::ProbeMutable, x) -> (m.x = x; m.y), Tuple{ProbeMutable,Any}),  # write barrier
    ((v::Vector{Any}, i, x) -> (v[i] = x; nothing), Tuple{Vector{Any},Int,Any}),
    ((x) -> GC.@preserve(x, probe_throws(1)), Tuple{Vector{Int}}),      # gc_preserve
    ((x) -> typeof(x), Tuple{Any}),
    ((v::Vector{Float64}, i) -> (v[i] = 1.0; length(v)), Tuple{Vector{Float64},Int}),
    ((x) -> pointer_from_objref(x), Tuple{ProbeMutable}),
    ((x) -> try probe_throws(x) catch; 0 end, Tuple{Int}),              # exceptions
    ((r::Base.RefValue{ProbeImmutable}) -> r[].y, Tuple{Base.RefValue{ProbeImmutable}}),
    ((v::Vector{Union{Nothing,Int}}, i) -> v[i], Tuple{Vector{Union{Nothing,Int}},Int}),
    ((m::Memory{Int}) -> length(m), Tuple{Memory{Int}}),
    ((s::String) -> sizeof(s), Tuple{String}),
]

native_probe_modules() = [native_module_ir(f, tt) for (f, tt) in NATIVE_PROBES]
