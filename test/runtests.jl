using PackageCompilerX: PackageCompilerX, create_sysimage, create_app
using Test
using Libdl

ENV["JULIA_DEBUG"] = "PackageCompilerX"

@testset "PackageCompilerX.jl" begin
    tmp = mktempdir()
    sysimage_path = joinpath(tmp, "sys." * Libdl.dlext)
    create_sysimage(:Example; sysimage_path=sysimage_path,
                              precompile_execution_file="precompile_execution.jl",
                              precompile_statements_file=["precompile_statements.jl",
                                                          "precompile_statements2.jl"])
    run(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'println(1337)'`)

    # Test creating an app
    app_source_dir = joinpath(@__DIR__, "..", "examples/MyApp/")

    # TODO: Also test something that actually gives audit warnings
    @test_logs PackageCompilerX.audit_app(app_source_dir)
    app_compiled_dir = joinpath(tmp, "MyApp")
    for incremental in (true, false)
        if incremental == false
            filter_stdlibs = (true, false)
        else
            filter_stdlibs = (false,)
        end
        for filter in filter_stdlibs
            create_app(app_source_dir, app_compiled_dir; incremental=incremental, force=true, filter_stdlibs=filter)
            app_path = abspath(app_compiled_dir, "bin", "MyApp" * (Sys.iswindows() ? ".exe" : ""))
            app_output = read(`$app_path`, String)

            # Check stdlib filtering
            if filter == true
                @test !(occursin("LinearAlgebra", app_output))
            else
                @test occursin("LinearAlgebra", app_output)
            end
            # Check dependency run
            @test occursin("Example.domath", app_output)
            # Check jll package runs
            @test occursin("Hello, World!", app_output)
            # Check artifact runs
            @test occursin("The result of 2*5^2 - 10 == 40.000000", app_output)
            # Check artifact gets run from the correct place
            @test occursin("HelloWorld artifact at $(realpath(app_compiled_dir))", app_output)
        end
    end
end
