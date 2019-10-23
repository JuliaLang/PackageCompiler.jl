using Documenter, PackageCompilerX

makedocs(
    sitename = "PackageCompilerX",
    pages = Any[
        "Home" => "index.md",
        "Examples" => Any[
            "examples/ohmyrepl.md"
        ]
    ]
)

deploydocs(
    repo = "github.com/KristofferC/PackageCompilerX.jl.git",
)
