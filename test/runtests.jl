using PackageCompilerX: PackageCompilerX, create_sysimage, create_app
using Test
using Libdl

ENV["JULIA_DEBUG"] = "PackageCompilerX"

# Make a new depot
new_depot = mktempdir()
@show DEPOT_PATH
mkpath(joinpath(new_depot, "registries"))
cp(joinpath(DEPOT_PATH[1], "registries", "General"), joinpath(new_depot, "registries", "General"))
ENV["JULIA_DEPOT_PATH"] = new_depot
Base.init_depot_path()

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
    app_compiled_dir = joinpath(tmp, "MyAppCompiled")
    for incremental in (true, false)
        if incremental == false
            filter_stdlibs = (true, false)
        else
            filter_stdlibs = (false,)
        end
        for filter in filter_stdlibs
            tmp_app_source_dir = joinpath(tmp, "MyApp")
            cp(app_source_dir, tmp_app_source_dir)
            create_app(tmp_app_source_dir, app_compiled_dir; incremental=incremental, force=true, filter_stdlibs=filter,
                       precompile_execution_file=joinpath(app_source_dir, "precompile_app.jl"))
            rm(tmp_app_source_dir; recursive=true)
            # Get rid of some local state
            rm(joinpath(new_depot, "packages"); recursive=true)
            rm(joinpath(new_depot, "compiled"); recursive=true)
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
