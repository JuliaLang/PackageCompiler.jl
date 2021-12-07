using PackageCompiler: PackageCompiler, create_sysimage, create_app, create_library
using Test
using Libdl
using Pkg

ENV["JULIA_DEBUG"] = "PackageCompiler"

# Make a new depot
new_depot = mktempdir()
mkpath(joinpath(new_depot, "registries"))
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
    write(script, """
    script_func() = println(\"I am a script\")
    opt_during_sysimage = Base.JLOptions().opt_level
    print_opt() = println("opt: -O\$opt_during_sysimage")
    """)
    create_sysimage(; sysimage_path=sysimage_path,
                              project=new_project,
                              precompile_execution_file=joinpath(@__DIR__, "precompile_execution.jl"),
                              precompile_statements_file=joinpath.(@__DIR__, ["precompile_statements.jl",
                                                                              "precompile_statements2.jl"]),
                              script=script,
                              sysimage_build_args = `-O1`
                              )

    # Check we can load sysimage and that Example is available in Main
    str = read(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'println(Example.hello("foo")); script_func(); print_opt()'`, String)
    @test occursin("Hello, foo", str)
    @test occursin("I am a script", str)
    @test occursin("opt: -O1", str)

    # Test creating an app
    app_source_dir = joinpath(@__DIR__, "..", "examples/MyApp/")
    app_compiled_dir = joinpath(tmp, "MyAppCompiled")
    for incremental in (is_slow_ci ? (false,) : (true, false))
        if incremental == false
            filter_stdlibs = (is_slow_ci ? (true, ) : (true, false))
        else
            filter_stdlibs = (false,)
        end
        for filter in filter_stdlibs
            tmp_app_source_dir = joinpath(tmp, "MyApp")
            cp(app_source_dir, tmp_app_source_dir)
            create_app(tmp_app_source_dir, app_compiled_dir; incremental=incremental, force=true, filter_stdlibs=filter,
                       precompile_execution_file=joinpath(app_source_dir, "precompile_app.jl"), 
                       executables=["MyApp" => "julia_main", 
                                    "SecondApp" => "second_main",
                                    "ReturnType" => "wrong_return_type",
                                    "Error" => "erroring",
                                    "Undefined" => "undefined",
                                    ])
            rm(tmp_app_source_dir; recursive=true)
            # Get rid of some local state
            rm(joinpath(new_depot, "packages"); recursive=true)
            rm(joinpath(new_depot, "compiled"); recursive=true)
            rm(joinpath(new_depot, "artifacts"); recursive=true)
            app_path(app_name) = abspath(app_compiled_dir, "bin", app_name * (Sys.iswindows() ? ".exe" : ""))
            app_output = read(`$(app_path("MyApp")) I get --args --julia-args --threads=3 --check-bounds=yes -O1`, String)

            # Check stdlib filtering
            if filter == true
                @test !(occursin("LinearAlgebra", app_output))
            else
                @test occursin("LinearAlgebra", app_output)
            end
            # Check dependency run
            @test occursin("Example.domath", app_output)
            # Check PROGRAM_FILE
            @test occursin("Base.PROGRAM_FILE = $(repr(app_path("MyApp")))", app_output)
            # Check jll package runs
            @test occursin("Hello, World!", app_output)
            # Check artifact runs
            @test occursin("The result of 2*5^2 - 10 == 40.000000", app_output)
            # Check artifact gets run from the correct place
            @test occursin("HelloWorld artifact at $(realpath(app_compiled_dir))", app_output)
            # Check ARGS
            @test occursin("""ARGS = ["I", "get", "--args"]""", app_output)
            # Check julia-args
            @test occursin("(Base.JLOptions()).opt_level = 1", app_output)
            @test occursin("(Base.JLOptions()).nthreads = 3", app_output)
            @test occursin("(Base.JLOptions()).check_bounds = 1", app_output)
            # Check transitive inclusion of dependencies
            @test occursin("is_crayons_loaded() = true", app_output)
            # Check app is precompiled in a normal process
            @test occursin("outputo: ok", app_output)
            @test occursin("myrand: ok", app_output)
            # Check distributed
            @test occursin("n = 20000000", app_output)
            @test occursin("From worker 2:\t8", app_output)
            @test occursin("From worker 3:\t8", app_output)
            @test occursin("From worker 4:\t8", app_output)
            @test occursin("From worker 5:\t8", app_output)

            # Test second app
            app_output = read(`$(app_path("SecondApp"))`, String)
            @test occursin("Hello from second main", app_output)

            io = IOBuffer()
            p = run(pipeline(ignorestatus(`$(app_path("ReturnType"))`), stderr=io;))
            @test occursin("ERROR: expected a Cint return value from function MyApp.wrong_return_type", String(take!(io)))
            @test p.exitcode == 1

            io = IOBuffer()
            p = run(pipeline(ignorestatus(`$(app_path("Error"))`), stderr=io;))
            @test occursin("MethodError: no method matching +(", String(take!(io)))
            @test p.exitcode == 1

            io = IOBuffer()
            p = run(pipeline(ignorestatus(`$(app_path("Undefined"))`), stderr=io;))
            @test occursin("UndefVarError: undefined not defined", String(take!(io)))
            @test p.exitcode == 1
        end
    end

    if !is_slow_ci
        # Test library creation
        lib_source_dir = joinpath(@__DIR__, "..", "examples/MyLib")
        lib_target_dir = joinpath(tmp, "MyLibCompiled")

        incremental = false
        filter = true
        lib_name = "inc"

        tmp_lib_src_dir = joinpath(tmp, "MyLib")
        cp(lib_source_dir, tmp_lib_src_dir)
        create_library(tmp_lib_src_dir, lib_target_dir; incremental=incremental, force=true, filter_stdlibs=filter,
                    precompile_execution_file=joinpath(lib_source_dir, "build", "generate_precompile.jl"),
                    precompile_statements_file=joinpath(lib_source_dir, "build", "additional_precompile.jl"),
                    lib_name=lib_name, version=v"1.0.0")
        rm(tmp_lib_src_dir; recursive=true)
    end

    # Test creating an empty sysimage
    if !is_slow_ci
        tmp = mktempdir()
        sysimage_path = joinpath(tmp, "empty." * Libdl.dlext)
        foreach(x -> touch(joinpath(tmp, x)), ["Project.toml", "Manifest.toml"])
        create_sysimage(String[]; sysimage_path=sysimage_path, incremental=false, filter_stdlibs=true, project=tmp)
        hello = read(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'print("hello, world")'`, String)
        @test hello == "hello, world"
    end
end
