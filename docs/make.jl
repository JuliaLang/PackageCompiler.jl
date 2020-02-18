using Documenter, PackageCompiler

makedocs(
    format = Documenter.HTML(
        prettyurls = "deploy" in ARGS,
    ),
    sitename = "PackageCompiler",
    pages = [
        "Home" => "index.md",

        "Manual" => [
            "sysimages.md"
            "apps.md"
        ],

        "Examples" => [
            "examples/ohmyrepl.md",
            "examples/plots.md",
        ],

        "PackageCompiler - the manual way" => [
            "devdocs/intro.md",
            "devdocs/sysimages_part_1.md",
            "devdocs/binaries_part_2.md",
            "devdocs/relocatable_part_3.md",
        ],

        "References" => "refs.md",
        "Upgrade notes" => "upgrade.md",
    ]
)

deploydocs(
    repo = "github.com/JuliaLang/PackageCompiler.jl.git",
    push_preview = true,
)
