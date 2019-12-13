using Documenter, PackageCompilerX

makedocs(
    format = Documenter.HTML(
        prettyurls = "deploy" in ARGS,
    ),
    sitename = "PackageCompilerX",
    pages = [
        "Home" => "index.md",

        "Manual" => [
            "sysimages.md"
            "apps.md"
        ],

        "Examples" => [
            "examples/ohmyrepl.md",
        ],

        "PackageCompilerX - the manual way" => [
            "devdocs/intro.md",
            "devdocs/sysimages_part_1.md",
            "devdocs/binaries_part_2.md",
            "devdocs/relocatable_part_3.md",
        ],

        "References" => "refs.md",
    ]
)

deploydocs(
    repo = "github.com/KristofferC/PackageCompilerX.jl.git",
)
