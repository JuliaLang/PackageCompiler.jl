using PackageCompiler: PackageCompiler, create_sysimage, create_app, create_distribution, create_library
using Test
using Libdl
using Pkg

import TOML

ENV["JULIA_DEBUG"] = "PackageCompiler"

# Make a new depot
const new_depot = mktempdir()
mkpath(joinpath(new_depot, "registries"))
ENV["JULIA_DEPOT_PATH"] = new_depot
Base.init_depot_path()

# A generic CI variable, not specific to any single CI provider.
# Lots of different CI providers set the `CI` environment variable,
# such as GitHub Actions, Buildkite, and Travis CI.
# If I recall correctly, Julia's PkgEval.jl also sets it.
const is_ci = tryparse(Bool, get(ENV, "CI", "")) === true

# In order to be "slow CI", we must meet all of the following:
# 1. We are running on CI.
# 2. We are running on aarch64 (arm64).
# 3. We are NOT running on Apple Silicon macOS.
#    (Because for GitHub Actions, the GitHub-hosted Apple Silicon
#    macOS runners seem to be quite fast.)
const is_slow_ci = is_ci && Sys.ARCH == :aarch64 && !Sys.isapple()

if is_ci
    @info "This is a CI job" Sys.ARCH VERSION is_ci
end

if is_slow_ci
    @warn "This is \"slow CI\" (defined as any non-macOS CI running on aarch64). Some tests will be skipped or modified." Sys.ARCH
end

@testset "PackageCompiler.jl" begin
    @testset "create_sysimage" begin
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
    end # testset

    @testset "create_app" begin
    # Test creating an app
    app_source_dir = joinpath(@__DIR__, "..", "examples/MyApp/")
    app_compiled_dir = joinpath(tmp, "MyAppCompiled")
    if is_slow_ci
        incrementals_list = (true, false)
    else
        incrementals_list = (true, false)
    end
    @testset for incremental in incrementals_list
        if incremental == false
            if is_slow_ci
                @warn "Skipping the (incremental=false, filter_stdlibs=false) test because this is \"slow CI\""
                @test_skip false
                filter_stdlibs = (true,)
            else
                filter_stdlibs = (true, false)
            end
        else
            filter_stdlibs = (false,)
        end
        @testset for filter in filter_stdlibs
            @info "starting: create_app testset" incremental filter
            tmp_app_source_dir = joinpath(tmp, "MyApp")
            cp(app_source_dir, tmp_app_source_dir)
            try
            create_app(tmp_app_source_dir, app_compiled_dir; incremental=incremental, force=true, filter_stdlibs=filter, include_lazy_artifacts=true,
                       precompile_execution_file=joinpath(app_source_dir, "precompile_app.jl"),
                       executables=["MyApp" => "julia_main",
                                    "SecondApp" => "second_main",
                                    "ReturnType" => "wrong_return_type",
                                    "Error" => "erroring",
                                    "Undefined" => "undefined",
                                    ])
            finally
            rm(tmp_app_source_dir; recursive=true)
            # Get rid of some local state
            rm(joinpath(new_depot, "packages"); recursive=true, force=true)
            rm(joinpath(new_depot, "compiled"); recursive=true, force=true)
            rm(joinpath(new_depot, "artifacts"); recursive=true, force=true)
            end # try
            test_load_path = mktempdir()
            test_depot_path = mktempdir()
            app_path(app_name) = abspath(app_compiled_dir, "bin", app_name * (Sys.iswindows() ? ".exe" : ""))
            app_output = withenv("JULIA_DEPOT_PATH" => test_depot_path, "JULIA_LOAD_PATH" => test_load_path) do
                read(`$(app_path("MyApp")) I get --args áéíóú --julia-args --threads=3 --check-bounds=yes -O1`, String)
            end

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
            @test occursin("Artifact printed: Hello, World!", app_output)
            # Check artifact gets run from the correct place
            @test occursin("HelloWorld artifact at $(realpath(app_compiled_dir))", app_output)
            # Check ARGS
            @test occursin("""ARGS = ["I", "get", "--args", "áéíóú"]""", app_output)
            # Check julia-args
            @test occursin("(Base.JLOptions()).opt_level = 1", app_output)
            @test occursin("(Base.JLOptions()).nthreads = 3", app_output)
            @test occursin("(Base.JLOptions()).check_bounds = 1", app_output)
            # Check transitive inclusion of dependencies
            @test occursin("is_crayons_loaded() = true", app_output)
            # Check app is precompiled in a normal process
            @test occursin("outputo: ok", app_output)
            @test occursin("myrand: ok", app_output)
            # Check env-provided depot and load paths are accepted
            @test occursin("DEPOT_PATH = [\"$(escape_string(test_depot_path))", app_output)
            @test occursin("LOAD_PATH = [\"$(escape_string(test_load_path))", app_output)
            # Check distributed
            @test occursin("n = 20000000", app_output)
            @test occursin("From worker 2:\t8", app_output)
            @test occursin("From worker 3:\t8", app_output)
            @test occursin("From worker 4:\t8", app_output)
            @test occursin("From worker 5:\t8", app_output)


            @test occursin("LLVMExtra path: ok!", app_output)
            @test occursin("micromamba_jll path: ok!", app_output)

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
            str = String(take!(io))
            @test all(occursin(str), ["UndefVarError:", "undefined", "not defined"])
            @test p.exitcode == 1
            @info "done: create_app testset" incremental filter
        end
    end
    end # testset

    if !is_slow_ci
        @testset "create_distribution" begin
            dist_source_dir = joinpath(@__DIR__, "..", "examples/MyApp/")
            tmp_dist_source_dir = joinpath(tmp, "MyAppDistSource")
            cp(dist_source_dir, tmp_dist_source_dir)
            ctx = PackageCompiler.create_pkg_context(tmp_dist_source_dir)
            expected_entries = PackageCompiler.gather_dependency_entries(ctx)
            expected_names = [something(entry.name, string(entry.uuid)) for entry in expected_entries]
            dist_target_dir = joinpath(tmp, "CustomJulia")
            try
                create_distribution(tmp_dist_source_dir, dist_target_dir; force=true, include_lazy_artifacts=true)
            finally
                rm(tmp_dist_source_dir; recursive=true)
                rm(joinpath(new_depot, "packages"); recursive=true, force=true)
                rm(joinpath(new_depot, "compiled"); recursive=true, force=true)
                rm(joinpath(new_depot, "artifacts"); recursive=true, force=true)
            end
            julia_bin = joinpath(dist_target_dir, "bin", Base.julia_exename())
            output = read(`$(julia_bin) -e 'using Example; print(Example.hello("distribution"))'`, String)
            @test occursin("Hello, distribution", output)
            stdlib_version_dir = joinpath(dist_target_dir, "share", "julia", "stdlib", string('v', VERSION.major, '.', VERSION.minor))
            for name in expected_names
                project_path = joinpath(stdlib_version_dir, name, "Project.toml")
                stub_path = joinpath(stdlib_version_dir, name, "src", string(name, ".jl"))
                @test isfile(project_path)
                @test isfile(stub_path)
            end
        end

        @testset "create_library" begin
            # Test library creation
            lib_source_dir = joinpath(@__DIR__, "..", "examples/MyLib")
            lib_target_dir = joinpath(tmp, "MyLibCompiled")

            # This is why we have to skip this test on 1.12:
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
    end

    # Test creating an empty sysimage
    if !is_slow_ci
        tmp = mktempdir()
        sysimage_path = joinpath(tmp, "empty." * Libdl.dlext)
        foreach(x -> touch(joinpath(tmp, x)), ["Project.toml", "Manifest.toml"])

        # This is why we need to skip this test on 1.12:
        incremental=false

        create_sysimage(String[]; sysimage_path=sysimage_path, incremental=incremental, filter_stdlibs=true, project=tmp)
        hello = read(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'print("hello, world")'`, String)
        @test hello == "hello, world"
    end
end
