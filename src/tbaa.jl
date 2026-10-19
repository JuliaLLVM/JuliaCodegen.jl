# Type-based alias analysis metadata: the TBAA tree of Julia's code generator
# (`jl_tbaacache_t` in `src/codegen.cpp`), so that Julia's passes and LLVM see the same
# aliasing facts as for native code, e.g. that the data of an array does not alias its
# size, which lets loads of the size be hoisted out of loops.

"""
    JuliaCodegen.tbaa_tree(dialect::JuliaIR.Dialect) -> Dict{Symbol,Symbol}

The TBAA type nodes of the dialect's code generator, by name (without the `jtbaa_`
prefix), with the name of each one's parent (`:root` for the root `jtbaa`): the tree of
`jl_tbaacache_t::initialize`. Julia 1.14 restructured it: object fields are `field`
instead of `mutab` and `immut`, memory has a node of its own, and there is no `arraybuf`
any more.
"""
function tbaa_tree(dialect::JuliaIR.Dialect)
    if dialect.minor >= v"1.14"
        return Dict(:gcframe => :root, :stack => :root, :memoryselbyte => :root,
                    :data => :root, :value => :data, :field => :value,
                    :ptrmemorybuf => :value, :binding => :value, :datatype => :value,
                    :array => :value, :arrayptr => :array, :arraysize => :array,
                    :memory => :value, :memoryptr => :memory, :memorylen => :memory,
                    :memoryown => :memory, :const => :root, :coverage => :root)
    else
        return Dict(:gcframe => :root, :stack => :root, :unionselbyte => :stack,
                    :data => :root, :binding => :data, :value => :data, :mutab => :value,
                    :datatype => :mutab, :immut => :value, :arraybuf => :data,
                    :ptrarraybuf => :data, :array => :root, :arrayptr => :array,
                    :arraysize => :array, :arrayselbyte => :array, :memoryptr => :array,
                    :memorylen => :array, :memoryown => :array, :const => :root)
    end
end

"""
    JuliaCodegen.TBAA(dialect::JuliaIR.Dialect)

The TBAA metadata of one LLVM context: the type nodes and access tags of
[`tbaa_tree`](@ref JuliaCodegen.tbaa_tree), created on first use. Accesses tagged `:const`
are to constant memory, as in native code.
"""
struct TBAA
    tree::Dict{Symbol,Symbol}
    nodes::Dict{Symbol,LLVM.MDNode}
    tags::Dict{Symbol,LLVM.MDNode}
end
TBAA(dialect::JuliaIR.Dialect) = TBAA(tbaa_tree(dialect), Dict{Symbol,LLVM.MDNode}(),
                                      Dict{Symbol,LLVM.MDNode}())

md_i64(x) = LLVM.Metadata(LLVM.ConstantInt(LLVM.Int64Type(), x))

# the type node of `kind`
function tbaa_node(t::TBAA, kind::Symbol)
    get!(t.nodes, kind) do
        if kind === :root
            # the root of Julia's tree is `!{!"jtbaa", !{!"jtbaa"}, i64 0}`
            LLVM.MDNode([LLVM.MDString("jtbaa"), LLVM.MDNode([LLVM.MDString("jtbaa")]), md_i64(0)])
        else
            parent = get(t.tree, kind, nothing)
            parent === nothing && throw(ArgumentError("no TBAA node jtbaa_$kind in this dialect"))
            LLVM.MDNode([LLVM.MDString("jtbaa_" * String(kind)), tbaa_node(t, parent), md_i64(0)])
        end
    end
end

"""
    JuliaCodegen.tbaa_tag(t::TBAA, kind::Symbol) -> LLVM.MDNode

The TBAA access tag for memory of `kind`, e.g. `:gcframe` or `:const`.
"""
function tbaa_tag(t::TBAA, kind::Symbol)
    get!(t.tags, kind) do
        node = tbaa_node(t, kind)
        fields = LLVM.Metadata[node, node, md_i64(0)]
        kind === :const && push!(fields, md_i64(1))
        LLVM.MDNode(fields)
    end
end

"Tag `inst` as an access to memory of `kind`."
function tbaa!(t::TBAA, inst::LLVM.Instruction, kind::Symbol)
    inst.metadata[LLVM.MD_tbaa] = tbaa_tag(t, kind)
    return inst
end
