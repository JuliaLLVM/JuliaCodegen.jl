# The configuration of a compilation.

"""
    JuliaCodegen.CodegenConfig(; target=host_target(), dialect=JuliaIR.Dialect(VERSION),
                               on_unsupported=:fallback, on_internal_error=:fallback)

The configuration of the code generator, which generates code for the running Julia:

- `target`: the [`Target`](@ref JuliaCodegen.Target) to generate code for;
- `dialect`: the conventions of the running Julia's IR, a `JuliaIR.Dialect`; pass one to
  set its policies, such as the GC write-barrier configuration
  (`JuliaIR.Dialect(VERSION; gc_barrier=:snapshot)`);
- `on_unsupported`, `on_internal_error`: what happens when a function uses an unsupported
  construct, or the code generator fails: `:fallback` to Julia's code generator (internal
  errors are reported), or `:error`. Tests use `:error` for both.

The facts about the running Julia's runtime are `config.runtime`, see
[`RuntimeFacts`](@ref JuliaCodegen.RuntimeFacts).
"""
struct CodegenConfig
    target::Target
    dialect::JuliaIR.Dialect
    runtime::RuntimeFacts
    on_unsupported::Symbol
    on_internal_error::Symbol

    function CodegenConfig(target::Target, dialect::JuliaIR.Dialect, on_unsupported::Symbol,
                           on_internal_error::Symbol)
        dialect.minor == JuliaIR.Dialect(VERSION).minor ||
            throw(ArgumentError("$dialect is not the dialect of the running Julia; code is only generated for the running Julia"))
        for (name, value) in ((:on_unsupported, on_unsupported),
                              (:on_internal_error, on_internal_error))
            value in FAILURE_POLICIES ||
                throw(ArgumentError("invalid $name policy :$value; expected one of $(join(FAILURE_POLICIES, ", "))"))
        end
        new(target, dialect, runtime_facts(), on_unsupported, on_internal_error)
    end
end

CodegenConfig(; target::Target=host_target(), dialect::JuliaIR.Dialect=JuliaIR.Dialect(VERSION),
              on_unsupported::Symbol=:fallback, on_internal_error::Symbol=:fallback) =
    CodegenConfig(target, dialect, on_unsupported, on_internal_error)
