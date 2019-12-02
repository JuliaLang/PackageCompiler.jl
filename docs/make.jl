using Documenter, PackageCompilerX

makedocs(
    format = Documenter.HTML(
        # prettyurls on travis
        prettyurls = haskey(ENV, "HAS_JOSH_K_SEAL_OF_APPROVAL"),
    ),
    sitename = "PackageCompilerX",
    pages = Any[
        "Home" => "index.md",
        "Manual" => [
            "prereq.md"
            "sysimages.md"
            "apps.md"
        ],

        "Examples" => Any[
            "examples/ohmyrepl.md",
        ],
        "References" => "refs.md",
    ]
)

deploydocs(
    repo = "github.com/KristofferC/PackageCompilerX.jl.git",
)
