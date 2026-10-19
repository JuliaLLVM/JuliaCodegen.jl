# Errors, and what the code generator does when it cannot compile something.

"""
    JuliaCodegen.Unsupported(parts...)

Thrown when code uses a construct the code generator does not support. The message is
the concatenation of `parts`, which is only built when the error is shown: building it
when the error is thrown would show types and methods from the world the code generator
runs in, which may predate them.
"""
struct Unsupported <: Exception
    parts::Vector{Any}
    Unsupported(parts...) = new(Any[parts...])
end

Base.showerror(io::IO, e::Unsupported) =
    print(io, "JuliaCodegen: unsupported: ", e.parts...)

"Throw an [`Unsupported`](@ref JuliaCodegen.Unsupported) error with the message `parts`."
unsupported(parts...) = throw(Unsupported(parts...))

"""
    JuliaCodegen.InternalError

An error of the code generator itself (any exception other than
[`Unsupported`](@ref JuliaCodegen.Unsupported)) while compiling `context`, with the
original exception and its backtrace.
"""
struct InternalError <: Exception
    context::Any
    exception::Any
    "The backtrace, as returned by `catch_backtrace()`."
    backtrace::Any
end

function Base.showerror(io::IO, e::InternalError)
    print(io, "JuliaCodegen: internal error while compiling ", e.context, ": ")
    showerror(io, e.exception, e.backtrace)
end

"""
    JuliaCodegen.MissingCapability(capability, what)

Thrown when `what` needs a capability of the Julia runtime (see
[`JuliaCodegen.Capabilities`](@ref)) that the running Julia does not have.
"""
struct MissingCapability <: Exception
    capability::Symbol
    what::String
end

Base.showerror(io::IO, e::MissingCapability) =
    print(io, "JuliaCodegen: ", e.what, " needs the `", e.capability,
          "` capability, which this Julia does not provide")

"""
The policies for what happens when compiling something fails:

- `:fallback`: leave it to Julia's own code generator (or, inside a function being
  compiled, to the runtime);
- `:error`: throw.
"""
const FAILURE_POLICIES = (:fallback, :error)

"""
    handle_failure(config, context, err, bt) -> :fallback

Apply `config`'s failure policies to an exception `err` (with backtrace `bt`) thrown
while compiling `context`: rethrow it, or return `:fallback` when the caller should fall
back. An [`Unsupported`](@ref JuliaCodegen.Unsupported) error follows
`config.on_unsupported`. Any other error is an internal error: it follows
`config.on_internal_error`, and is reported (once per `context`) when falling back, so
that bugs of the code generator are never silent.
"""
function handle_failure(config, @nospecialize(context), @nospecialize(err), bt)
    if err isa Unsupported
        config.on_unsupported === :fallback && return :fallback
        throw(err)
    end
    ierr = InternalError(context, err, bt)
    config.on_internal_error === :fallback || throw(ierr)
    @error "JuliaCodegen failed; falling back" exception=(err, bt) context _id=objectid(context) maxlog=1
    return :fallback
end
