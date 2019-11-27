using PackageCompilerX
using Test
using Libdl

@testset "PackageCompilerX.jl" begin
    tmp = mktempdir()
    sysimage_path = joinpath(tmp, "sys." * Libdl.dlext)
    PackageCompilerX.create_sysimage(:Example; sysimage_path=sysimage_path,
                                     precompile_execution_file="precompile_execution.jl",
                                     precompile_statements_file="precompile_statements.jl")
    run(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'println(1337)'`)

    # Test creating an app
    app_source_dir = joinpath(@__DIR__, "..", "examples/MyApp/")
    app_exe_dir = joinpath(tmp, "MyApp")
    PackageCompilerX.create_app(app_source_dir, app_exe_dir)
    app_path = abspath(app_exe_dir, "bin", "MyApp" * (Sys.iswindows() ? ".exe" : ""))
    app_output = read(`$app_path`, String)
    @test occursin("Example.domath", app_output)
    @test occursin("ἔοικα γοῦν τούτου", app_output)
end
