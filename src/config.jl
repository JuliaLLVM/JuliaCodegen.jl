# The configuration of a compilation.

"""
    JuliaCodegen.CodegenConfig(; target=host_target(),
                               on_unsupported=:fallback, on_internal_error=:fallback)

The configuration of the code generator, which generates code for the running Julia (its
IR conventions and runtime):

- `target`: the [`Target`](@ref JuliaCodegen.Target) to generate code for;
- `on_unsupported`, `on_internal_error`: what happens when a function uses an unsupported
  construct, or the code generator fails: `:fallback` to Julia's code generator (internal
  errors are reported), or `:error`. Tests use `:error` for both.
"""
struct CodegenConfig
    target::Target
    on_unsupported::Symbol
    on_internal_error::Symbol

    function CodegenConfig(target::Target, on_unsupported::Symbol, on_internal_error::Symbol)
        for (name, value) in ((:on_unsupported, on_unsupported),
                              (:on_internal_error, on_internal_error))
            value in FAILURE_POLICIES ||
                throw(ArgumentError("invalid $name policy :$value; expected one of $(join(FAILURE_POLICIES, ", "))"))
        end
        new(target, on_unsupported, on_internal_error)
    end
end

CodegenConfig(; target::Target=host_target(), on_unsupported::Symbol=:fallback,
              on_internal_error::Symbol=:fallback) =
    CodegenConfig(target, on_unsupported, on_internal_error)
