using PackageCompiler, Pkg

dir(f...) = joinpath(@__DIR__, f...)
cd(@__DIR__)
build_executable(
    dir("makietest.jl"),
    "makie",
    dir("..", "examples", "program.c");
    snoopfile = dir("makiesnoop.jl"),
    builddir = dir("build"),
    verbose = true, quiet = false,
    cpu_target = "x86-64", optimize = "3"
)
PackageCompiler.build_object(
    dir("build", "julia_main.jl"), dir("build"), dir("build", "makie.o"), true,
    nothing, nothing, "x86-64", "3", nothing, nothing, nothing,
    nothing, nothing
)


packages = [
    "Quaternions",
    "GLVisualize",
    "StaticArrays",
    "GeometryTypes",
    "Reactive",
    "GLAbstraction",
    "GLWindow",
    "AbstractNumbers",
    "Contour",
    "FileIO",
    "Images",
    "UnicodeFun",
    "ColorBrewer",
    "Interact", # for displaying signals of Image - a bit unfortunate
    "Hiccup",
    "Media",
    "Juno",
    "ModernGL",
    "GLFW",
    "Fontconfig",
    "FreeType",
    "FreeTypeAbstraction",
    "ImageMagick",
]

for elem in packages
    cp(normpath(Base.find_package(elem), "..", ".."), dir("build", elem))
end
