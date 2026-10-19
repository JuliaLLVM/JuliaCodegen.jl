# What the running Julia offers external code generators. Detected when the package is
# loaded (not when it is precompiled: a precompiled cache can be loaded by another build
# of the same Julia version).

"""
    JuliaCodegen.Capabilities

The interfaces of the Julia runtime that the code generator can use. Some are not part of
any Julia release yet; parts of the code generator that need a missing one throw a
[`MissingCapability`](@ref JuliaCodegen.MissingCapability) error, and emission uses a
fallback where there is one.

$(join(("- `$(name)`" for name in (:codegen_abi, :publish, :codegen_hook, :aot_hook,
                                    :add_module, :specsig_layout, :dialect)), "\n"))

See the fields for what each one is. `JuliaCodegen.capabilities()` returns those of the
running Julia; `Capabilities(; kwargs...)` constructs a set for tests (missing keywords
are `false`).
"""
Base.@kwdef struct Capabilities
    "`Base.Experimental.codegen_abi`: the runtime's ABI facts (offsets, small type tags)."
    codegen_abi::Bool = false
    "`Base.Experimental.publish_codeinst!`: publishing code into a `CodeInstance`."
    publish::Bool = false
    "`Base.Experimental.set_codegen_hook!`: being called to compile CodeInstances for the JIT."
    codegen_hook::Bool = false
    "`Base.Experimental.CodegenOutput`: being called to compile CodeInstances for images."
    aot_hook::Bool = false
    "`Base.Experimental.add_codeinsts_module!`: submitting a module with its linker
    information to Julia's JIT."
    add_module::Bool = false
    "`jl_get_specsig_layout`: how native code passes arguments and returns values."
    specsig_layout::Bool = false
    "The Julia LLVM dialect's builders and verifier, in libjulia-codegen and LLVM.jl."
    dialect::Bool = false
end

function Base.show(io::IO, c::Capabilities)
    print(io, "JuliaCodegen.Capabilities(")
    join(io, (name for name in fieldnames(Capabilities) if getfield(c, name)), ", ")
    print(io, ")")
end

"""
    JuliaCodegen.capabilities() -> Capabilities

The capabilities of the running Julia.
"""
capabilities() = CAPABILITIES()

const CAPABILITIES = OncePerProcess{Capabilities}(() -> detect_capabilities())

has_experimental(name::Symbol) = isdefined(Base.Experimental, name)

function has_symbol(lib::AbstractString, name::Symbol)
    handle = Libdl.dlopen(lib; throw_error=false)
    handle === nothing && return false
    return Libdl.dlsym(handle, name; throw_error=false) !== nothing
end

function detect_capabilities()
    return Capabilities(;
        codegen_abi = has_experimental(:codegen_abi),
        publish = has_experimental(:publish_codeinst!),
        codegen_hook = has_experimental(:set_codegen_hook!),
        aot_hook = has_experimental(:CodegenOutput),
        add_module = has_experimental(:add_codeinsts_module!),
        specsig_layout = has_symbol("libjulia-codegen", :jl_get_specsig_layout_impl) ||
                         has_symbol("libjulia-internal", :jl_get_specsig_layout),
        dialect = isdefined(LLVM.Interop, :gc_alloc_obj!) &&
                  has_symbol("libjulia-codegen", :JLBuildGCAllocObj),
    )
end

"""
    JuliaCodegen.require(caps::Capabilities, capability::Symbol, what)

Throw a [`MissingCapability`](@ref JuliaCodegen.MissingCapability) error unless `caps` has
`capability`, which `what` (a description, for the message) needs.
"""
function require(caps::Capabilities, capability::Symbol, what::AbstractString)
    getfield(caps, capability)::Bool || throw(MissingCapability(capability, what))
    return nothing
end
