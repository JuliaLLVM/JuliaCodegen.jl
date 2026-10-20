# The configuration of a compilation.

"""
    JuliaCodegen.CodegenConfig(; target=host_target(), dialect=JuliaIR.Dialect(VERSION),
                               on_unsupported=:fallback, on_internal_error=:fallback,
                               gcstack_arg=true, safepoint_on_entry=true,
                               debug_info=:none)

The configuration of the code generator, which generates code for the running Julia:

- `target`: the [`Target`](@ref JuliaCodegen.Target) to generate code for;
- `dialect`: the conventions of the running Julia's IR, a `JuliaIR.Dialect`; pass one to
  set its policies, such as the GC write-barrier configuration
  (`JuliaIR.Dialect(VERSION; gc_barrier=:snapshot)`);
- `on_unsupported`, `on_internal_error`: what happens when a function uses an unsupported
  construct, or the code generator fails: `:fallback` to Julia's code generator (internal
  errors are reported), or `:error`. Tests use `:error` for both;
- `gcstack_arg`, `safepoint_on_entry`: as Julia's `CodegenParams`, whether entries in the
  specsig convention take the pgcstack as an argument (`swiftself`; without it, they use
  the C calling convention), and whether functions poll for a safepoint on entry. Targets
  without Julia's runtime, like GPUs, turn both off;
- `debug_info`: the debug information to emit, as the `debug_info_kind` of Julia's
  `CodegenParams`: `:none`, or line tables (a subprogram per function and the location
  of every statement, with inlined frames) in a compile unit of the emission kind
  `:line_tables`, `:directives` or `:full`, or `:no_debug`, which native code emits for
  the kind `NoDebug` (unless Julia runs with `-g0`): for tools reading locations, like
  GPUCompiler's error messages, which strip them later.

The facts about the running Julia's runtime are `config.runtime`, see
[`RuntimeFacts`](@ref JuliaCodegen.RuntimeFacts).
"""
struct CodegenConfig
    target::Target
    dialect::JuliaIR.Dialect
    runtime::RuntimeFacts
    on_unsupported::Symbol
    on_internal_error::Symbol
    gcstack_arg::Bool
    safepoint_on_entry::Bool
    debug_info::Symbol

    function CodegenConfig(target::Target, dialect::JuliaIR.Dialect, on_unsupported::Symbol,
                           on_internal_error::Symbol, gcstack_arg::Bool, safepoint_on_entry::Bool,
                           debug_info::Symbol)
        dialect.minor == JuliaIR.Dialect(VERSION).minor ||
            throw(ArgumentError("$dialect is not the dialect of the running Julia; code is only generated for the running Julia"))
        for (name, value) in ((:on_unsupported, on_unsupported),
                              (:on_internal_error, on_internal_error))
            value in FAILURE_POLICIES ||
                throw(ArgumentError("invalid $name policy :$value; expected one of $(join(FAILURE_POLICIES, ", "))"))
        end
        debug_info in (:none, :no_debug, :line_tables, :directives, :full) ||
            throw(ArgumentError("invalid debug_info :$debug_info; expected none, no_debug, line_tables, directives or full"))
        new(target, dialect, runtime_facts(), on_unsupported, on_internal_error, gcstack_arg,
            safepoint_on_entry, debug_info)
    end
end

CodegenConfig(; target::Target=host_target(), dialect::JuliaIR.Dialect=JuliaIR.Dialect(VERSION),
              on_unsupported::Symbol=:fallback, on_internal_error::Symbol=:fallback,
              gcstack_arg::Bool=true, safepoint_on_entry::Bool=true,
              debug_info::Symbol=:none) =
    CodegenConfig(target, dialect, on_unsupported, on_internal_error, gcstack_arg,
                  safepoint_on_entry, debug_info)
