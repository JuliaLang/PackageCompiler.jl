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

    # Test creating an app without bundling
    app_dir = joinpath(@__DIR__, "..", "examples/MyApp/")
    PackageCompilerX.create_app(app_dir)
    app_path = abspath(app_dir, "MyApp" * (Sys.iswindows() ? ".exe" : ""))
    app_output = read(`$app_path`, String)
    @test occursin("Example.domath", app_output)
end
