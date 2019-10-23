using PackageCompilerX
using Test
using Libdl

@testset "PackageCompilerX.jl" begin
    # Write your own tests here.
    sysimage_path = "sys." * Libdl.dlext
    PackageCompilerX.create_sysimage(:Example; sysimage_path=sysimage_path,
                                     precompile_execution_file="precompile_execution.jl",
                                     precompile_statements_file="precompile_statements.jl")
    run(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'println(1337)'`)
    PackageCompilerX.create_executable_from_sysimage(sysimage_path=sysimage_path,
                                                     executable_path="myapp")

    appname = abspath("myapp" * (Sys.iswindows() ? ".exe" : ""))
    output = read(`$(appname)`, String)
    @test occursin("hello, world", output)
end
