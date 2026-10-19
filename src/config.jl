# The configuration of a compilation.

"The oldest Julia version whose IR the code generator can emit."
const OLDEST_JULIA = v"1.12"

"""
    JuliaCodegen.CodegenConfig(; target=host_target(), julia=VERSION,
                               on_unsupported=:fallback, on_internal_error=:fallback)

The configuration of the code generator:

- `target`: the [`Target`](@ref JuliaCodegen.Target) to generate code for;
- `julia`: the Julia version whose IR conventions the output follows (1.12 or later); a
  prerelease follows the conventions of the release it precedes;
- `on_unsupported`, `on_internal_error`: what happens when a function uses an unsupported
  construct, or the code generator fails: `:fallback` to Julia's code generator (internal
  errors are reported), or `:error`. Tests use `:error` for both.
"""
struct CodegenConfig
    target::Target
    julia::VersionNumber
    on_unsupported::Symbol
    on_internal_error::Symbol

    function CodegenConfig(target::Target, julia::VersionNumber, on_unsupported::Symbol,
                           on_internal_error::Symbol)
        VersionNumber(julia.major, julia.minor) >= OLDEST_JULIA ||
            throw(ArgumentError("Julia $julia is not supported; the oldest supported version is $OLDEST_JULIA"))
        for (name, value) in ((:on_unsupported, on_unsupported),
                              (:on_internal_error, on_internal_error))
            value in FAILURE_POLICIES ||
                throw(ArgumentError("invalid $name policy :$value; expected one of $(join(FAILURE_POLICIES, ", "))"))
        end
        new(target, julia, on_unsupported, on_internal_error)
    end
end

CodegenConfig(; target::Target=host_target(), julia::VersionNumber=VERSION,
              on_unsupported::Symbol=:fallback, on_internal_error::Symbol=:fallback) =
    CodegenConfig(target, julia, on_unsupported, on_internal_error)
