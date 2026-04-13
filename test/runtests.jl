using PackageCompiler: PackageCompiler, create_sysimage, create_app, create_library
using Test
using Libdl
using Pkg

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

# GitHub Actions shards the expensive build configurations across its test
# matrix. Other test runners keep exercising every configuration by default.
const app_configuration = get(ENV, "PACKAGECOMPILER_TEST_APP_CONFIGURATION", "all")
const extended_tests = get(ENV, "PACKAGECOMPILER_TEST_EXTENDED", "all")

function app_configurations()
    configurations = if app_configuration == "all"
        ((true, false), (false, true), (false, false))
    elseif app_configuration == "default"
        ((false, false),)
    elseif app_configuration == "incremental"
        ((true, false),)
    elseif app_configuration == "filtered"
        ((false, true),)
    else
        error("unknown PACKAGECOMPILER_TEST_APP_CONFIGURATION=$(repr(app_configuration))")
    end

    if app_configuration == "all" && is_slow_ci
        return ((true, false), (false, true))
    end
    return configurations
end

extended_tests in ("all", "none", "sysimage", "library") ||
    error("unknown PACKAGECOMPILER_TEST_EXTENDED=$(repr(extended_tests))")

if is_ci
    @info "This is a CI job" Sys.ARCH VERSION is_ci app_configuration extended_tests
end

if is_slow_ci
    @warn "This is \"slow CI\" (defined as any non-macOS CI running on aarch64). Some tests will be skipped or modified." Sys.ARCH
end

# Sometimes directories seem to fail to clean up on CI (for undiagnosed
# reasons), so retry them.
function rm_with_retry(path; recursive::Bool=false, force::Bool=false,
                       attempts::Int=20, max_delay::Real=5.0)
    if isdir(path)
        Base.Filesystem.prepare_for_deletion(path)
    end
    # exponentially increase delay for the first ~half of attempts
    delay = Float64(max_delay) / 2.0^(attempts ÷ 2)
    for i in 1:attempts
        try
            rm(path; recursive=recursive, force=force)
            return
        catch e
            (e isa Base.IOError && i < attempts) || rethrow()
            sleep(delay)
            delay = min(delay * 2, max_delay)
        end
    end
end

@testset "PackageCompiler.jl" begin
    expected_sysimage_cpu_target = VERSION >= v"1.13-" ? "sysimage" : "native"
    @test PackageCompiler.DEFAULT_SYSIMAGE_CPU_TARGET == expected_sysimage_cpu_target

    @testset "julia_libdir / julia_private_libdir" begin
        lib_dir = PackageCompiler.julia_libdir()
        private_libdir = PackageCompiler.julia_private_libdir()
        @test isdir(lib_dir)
        @test isdir(private_libdir)
        for lib in ("libjulia-codegen", "libjulia-internal")
            @test !isempty(PackageCompiler.glob(PackageCompiler.glob_pattern_lib(lib), private_libdir))
        end
        # `bundle_julia_libraries` reproduces this layout inside the bundle. Framework
        # builds are the exception: they keep the private libraries in `Frameworks/`.
        if !Base.DARWIN_FRAMEWORK
            @test private_libdir in (lib_dir, joinpath(lib_dir, "julia"))
        end
    end

    tmp = mktempdir()

    if extended_tests in ("all", "sysimage")
        @testset "create_sysimage" begin
            new_project = mktempdir()
            old_project = Base.ACTIVE_PROJECT[]
            Base.ACTIVE_PROJECT[] = new_project
            try
                Pkg.add("Example")
            finally
                Base.ACTIVE_PROJECT[] = old_project
            end
            sysimage_path = joinpath(tmp, "sys." * Libdl.dlext)
            script = tempname()
            write(script, """
            script_func() = println(\"I am a script\")
            opt_during_sysimage = Base.JLOptions().opt_level
            print_opt() = println("opt: -O\$opt_during_sysimage")
            """)
            # Exercise sysimage compression on Julia versions that support it
            compress_sysimage = PackageCompiler.supports_sysimage_compression()
            create_sysimage(; sysimage_path,
                            project=new_project,
                            precompile_execution_file=joinpath(@__DIR__, "precompile_execution.jl"),
                            precompile_statements_file=joinpath.(@__DIR__, ["precompile_statements.jl",
                                                                          "precompile_statements2.jl"]),
                            script,
                            sysimage_build_args=`-O1`,
                            compress_sysimage)

            # Check we can load sysimage and that Example is available in Main
            str = read(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'println(Example.hello("foo")); script_func(); print_opt()'`, String)
            @test occursin("Hello, foo", str)
            @test occursin("I am a script", str)
            @test occursin("opt: -O1", str)

            if !PackageCompiler.supports_sysimage_compression()
                @test_throws "requires Julia v1.13" create_sysimage(; sysimage_path,
                                                                    project=new_project,
                                                                    compress_sysimage=true)
            end
        end
    end

    @testset "create_app" begin
        # Test creating an app
        app_source_dir = joinpath(@__DIR__, "..", "examples/MyApp/")
        app_compiled_dir = joinpath(tmp, "MyAppCompiled")
        if app_configuration == "all" && is_slow_ci
            @warn "Skipping the (incremental=false, filter_stdlibs=false) test because this is \"slow CI\""
            @test_skip false
        end
        @testset for (incremental, filter) in app_configurations()
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
            rm_with_retry(tmp_app_source_dir; recursive=true)
            # Get rid of some local state
            rm_with_retry(joinpath(new_depot, "packages"); recursive=true, force=true)
            rm_with_retry(joinpath(new_depot, "compiled"); recursive=true, force=true)
            rm_with_retry(joinpath(new_depot, "artifacts"); recursive=true, force=true)
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
            # From Julia 1.12, --threads=3 adds 1 interactive thread
            expected_threads = VERSION >= v"1.12-" ? 4 : 3
            @test occursin("(Base.JLOptions()).nthreads = $expected_threads", app_output)
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
    end # testset

    if !is_slow_ci && extended_tests in ("all", "library")
        @testset "create_library" begin
            # Test library creation
            lib_source_dir = joinpath(@__DIR__, "..", "examples/MyLib")
            lib_target_dir = joinpath(tmp, "MyLibCompiled")

            # Exercise nonincremental library creation with filtered stdlibs.
            incremental = false

            filter = true
            lib_name = "inc"

            tmp_lib_src_dir = joinpath(tmp, "MyLib")
            cp(lib_source_dir, tmp_lib_src_dir)
            create_library(tmp_lib_src_dir, lib_target_dir; incremental=incremental, force=true, filter_stdlibs=filter,
                           precompile_execution_file=joinpath(lib_source_dir, "build", "generate_precompile.jl"),
                           precompile_statements_file=joinpath(lib_source_dir, "build", "additional_precompile.jl"),
                           lib_name=lib_name, version=v"1.0.0", compat_level="patch")
            @test !isfile(splitext(PackageCompiler.default_julia_init())[1] * ".o")
            rm_with_retry(tmp_lib_src_dir; recursive=true)
        end
    end

    # Test creating an empty sysimage
    if !is_slow_ci && extended_tests in ("all", "sysimage")
        @testset "create_empty_sysimage" begin
            empty_tmp = mktempdir()
            sysimage_path = joinpath(empty_tmp, "empty." * Libdl.dlext)
            foreach(x -> touch(joinpath(empty_tmp, x)), ["Project.toml", "Manifest.toml"])

            # Exercise a nonincremental empty sysimage with filtered stdlibs.
            incremental = false

            create_sysimage(String[]; sysimage_path, incremental, filter_stdlibs=true, project=empty_tmp)
            hello = read(`$(Base.julia_cmd()) -J $(sysimage_path) -e 'print("hello, world")'`, String)
            @test hello == "hello, world"
        end
    end

    @testset "Workspace bundling" begin
        ctx = PackageCompiler.create_pkg_context(joinpath(@__DIR__, "subproject"))
        pkgs = PackageCompiler.load_all_deps(ctx)
        # on >=1.12; don't load the full workspace
        # on <1.12; it doesn't know it is in a workspace
        @test length(pkgs) == 1
        @test only(pkgs).name == "Example"

        # Requested packages are included even when explicit transitive loading is disabled.
        pkgids = PackageCompiler.package_ids_for_sysimage(ctx, ["Example"];
                                                          include_transitive_dependencies=false)
        @test only(pkgids).name == "Example"
    end

    @test applicable(create_sysimage, "Example")

    header_files = String[]
    missing_project = joinpath(mktempdir(), "missing")
    @test_throws ErrorException create_library(missing_project, tempname(); header_files)
    @test isempty(header_files)
end
