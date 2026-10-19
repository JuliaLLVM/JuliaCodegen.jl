# Where the code generator gets IR from: Julia's native inference, for now.

"""
    JuliaCodegen.method_instance(tt, world) -> Core.MethodInstance

The method instance that a call of the signature `tt` dispatches to in `world`.
"""
function method_instance(@nospecialize(tt::Type), world::UInt)
    match = Base._which(tt; world)
    return CC.specialize_method(match)
end

"""
    JuliaCodegen.get_ir(mi, world) -> (IRCode, rettype)

The optimized IR of `mi` in `world`, from Julia's native inference.
"""
function get_ir(mi::Core.MethodInstance, world::UInt)
    res = Base.code_ircode_by_type(mi.specTypes; world, optimize_until=nothing)
    length(res) == 1 || unsupported("no unique IR for ", mi.specTypes)
    ir, rt = res[1]
    return ir, rt
end

"""
    JuliaCodegen.emit_entry!(cgm, tt; name) -> (FuncInfo, LLVM.Function)

Emit the function for a call of the signature `tt`, and its jlcall entry wrapper named
`name`.
"""
function emit_entry!(cgm::CGModule, @nospecialize(tt::Type); name::AbstractString=unique_name(cgm, "jfptr"))
    mi = method_instance(tt, cgm.world)
    ir, rt = get_ir(mi, cgm.world)
    info = declare_function!(cgm, mi, signature_argtypes(mi), rt)
    emit_body!(cgm, info, ir)
    return info, emit_jlcall_wrapper!(cgm, info, name)
end
