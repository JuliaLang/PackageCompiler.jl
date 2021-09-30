using MyApp

push!(ARGS, "arg")
MyApp.julia_main()

using Example
Example.hello("PackageCompiler")

using Crayons