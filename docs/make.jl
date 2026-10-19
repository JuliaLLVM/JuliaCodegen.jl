using Documenter, JuliaCodegen

function main()
    ci = get(ENV, "CI", "") == "true"

    makedocs(
        sitename = "JuliaCodegen.jl",
        # explicit, so that local builds work in a checkout without a remote
        repo = Remotes.GitHub("JuliaLLVM", "JuliaCodegen.jl"),
        authors = "Valentin Churavy",
        format = Documenter.HTML(prettyurls = ci, edit_link = "main"),
        modules = [JuliaCodegen],
        pages = [
            "Home" => "index.md",
            "Testing" => "testing.md",
            "API reference" => "api.md",
            "Internals" => "internals.md",
        ],
        doctest = true,
    )

    if ci
        deploydocs(repo = "github.com/JuliaLLVM/JuliaCodegen.jl.git")
    end
end

isinteractive() || main()
