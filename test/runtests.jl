using PackageCompiler: PackageCompiler, create_sysimage, create_app
using Test
using Libdl
using Pkg

ENV["JULIA_DEBUG"] = "PackageCompiler"

# Make a new depot
new_depot = mktempdir()
mkpath(joinpath(new_depot, "registries"))
cp(joinpath(DEPOT_PATH[1], "registries", "General"), joinpath(new_depot, "registries", "General"))
ENV["JULIA_DEPOT_PATH"] = new_depot
Base.init_depot_path()

is_slow_ci = haskey(ENV, "CI") && Sys.ARCH == :aarch64

if haskey(ENV, "CI")
    @show Sys.ARCH
end

@testset "PackageCompiler.jl" begin
    new_project = mktempdir()
    old_project = Base.ACTIVE_PROJECT[]
    Base.ACTIVE_PROJECT[] = new_project
    try
        Pkg.add("Example")
    finally
        Base.ACTIVE_PROJECT[] = old_project
    end
    tmp = mktempdir()
    sysimage_path = joinpath(tmp, "sys." * Libdl.dlext)
    script = tempname()
    write(script, "script_func() = println(\"I am a script\")")
    create_sysimage(:Example; sysimage_path=sysimage_path,
                              project=new_project,
                              precompile_execution_file=joinpath(@__DIR__, "precompile_execution.jl"),
                              precompile_statements_file=joinpath.(@__DIR__, ["precompile_statements.jl",
                                                                              "precompile_statements2.jl"]),
                              script=script)
    # Check we can load sysimage and that Example is available in Main
    str = read(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'println(Example.hello("foo")); script_func()'`, String)
    @test occursin("Hello, foo", str)
    @test occursin("I am a script", str)

    # Test creating an app
    app_source_dir = joinpath(@__DIR__, "..", "examples/MyApp/")
    # TODO: Also test something that actually gives audit warnings
    @test_logs PackageCompiler.audit_app(app_source_dir)
    app_compiled_dir = joinpath(tmp, "MyAppCompiled")
    for incremental in (is_slow_ci ? (false,) : (true, false))
        if incremental == false
            filter_stdlibs = (is_slow_ci ? (true, ) : (true, false))
            binary_name_args = ("CustomName", nothing)
        else
            filter_stdlibs = (false,)
            binary_name_args = (nothing,)
        end
        for (filter, name) in zip(filter_stdlibs, binary_name_args)
            tmp_app_source_dir = joinpath(tmp, "MyApp")
            cp(app_source_dir, tmp_app_source_dir)
            create_app(tmp_app_source_dir, app_compiled_dir; incremental=incremental, force=true, filter_stdlibs=filter,
                       precompile_execution_file=joinpath(app_source_dir, "precompile_app.jl"), app_name=name)
            rm(tmp_app_source_dir; recursive=true)
            # Get rid of some local state
            rm(joinpath(new_depot, "packages"); recursive=true)
            rm(joinpath(new_depot, "compiled"); recursive=true)
            app_name = name !== nothing ? name : "MyApp"
            app_path = abspath(app_compiled_dir, "bin", app_name * (Sys.iswindows() ? ".exe" : ""))
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
    # Test creating an empty sysimage
    if !is_slow_ci
        tmp = mktempdir()
        sysimage_path = joinpath(tmp, "empty." * Libdl.dlext)
        foreach(x -> touch(joinpath(tmp, x)), ["Project.toml", "Manifest.toml"])
        create_sysimage(; sysimage_path=sysimage_path, incremental=false, filter_stdlibs=true, project=tmp)
        hello = read(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'print("hello, world")'`, String)
        @test hello == "hello, world"
    end
end
