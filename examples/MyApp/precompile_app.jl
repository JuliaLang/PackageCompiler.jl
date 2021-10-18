using MyApp

push!(ARGS, "arg")
MyApp.julia_main()

using Example
Example.hello("PackageCompiler")

using Crayons

# It is ok to use stdlibs that are not in the project dependencies
using Test
@test 1==1