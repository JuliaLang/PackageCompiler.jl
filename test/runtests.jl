using PackageCompiler: PackageCompiler, create_sysimage, create_app, create_library
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

# GHA = GitHub Actions
const is_gha_ci = tryparse(Bool, get(ENV, "GITHUB_ACTIONS", "")) === true

# In order to be "slow CI", we must meet all of the following:
# 1. We are running on CI.
# 2. We are running on aarch64 (arm64).
# 3. We are NOT running on Apple Silicon macOS.
#    (Because for GitHub Actions, the GitHub-hosted Apple Silicon
#    macOS runners seem to be quite fast.)
const is_slow_ci = is_ci && Sys.ARCH == :aarch64 && !Sys.isapple()

const is_julia_1_6 = VERSION.major == 1 && VERSION.minor == 6
const is_julia_1_9 = VERSION.major == 1 && VERSION.minor == 9
const is_julia_1_11 = VERSION.major == 1 && VERSION.minor == 11
const is_julia_1_12 = VERSION.major == 1 && VERSION.minor == 12

if is_ci || is_gha_ci
    @info "This is a CI job" Sys.ARCH VERSION is_ci is_gha_ci
end

if is_slow_ci
    @warn "This is \"slow CI\" (defined as any non-macOS CI running on aarch64). Some tests will be skipped or modified." Sys.ARCH
end

const jlver_some_tests_skipped = [
    is_julia_1_6,
    is_julia_1_9,
    is_julia_1_11,
    is_julia_1_12,
]

if any(jlver_some_tests_skipped)
    @warn "This is Julia $(VERSION.major).$(VERSION.minor). Some tests will be skipped or modified." VERSION
end

function remove_llvmextras(project_file)
    proj = TOML.parsefile(project_file)
    delete!(proj["deps"], "LLVMExtra_jll")
    open(project_file, "w") do io
        TOML.print(io, proj)
    end
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
            if is_gha_ci && (is_julia_1_11 || is_julia_1_12)
                # On Julia 1.11 and 1.12, `incremental=false` is currently broken.
                # 1.11: https://github.com/JuliaLang/PackageCompiler.jl/issues/976
                # 1.12: No GitHub issue yet.
                # So, for now, we skip the `incremental=false` tests on Julia 1.11 and 1.12
                # But ONLY on GHA (GitHub Actions).
                # On PkgEval, we do run these tests. This is intentional - we want PkgEval to
                # detect regressions, as well as fixes for those regressions.
                @warn "[GHA CI] This is Julia $(VERSION.major).$(VERSION.minor); skipping incremental=false test due to known bug: #976 (for 1.11), issue TODO (for 1.12)"
                @test_skip false
                continue
            end
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
            if is_gha_ci && (is_julia_1_6 || is_julia_1_9)
                # Julia 1.6: Issue #706 "Cannot locate artifact 'LLVMExtra'" on 1.6 so remove.
                # Julia 1.9: There's no GitHub Issue, but it seems we hit a similar problem.
                @test_skip false
                remove_llvmextras(joinpath(tmp_app_source_dir, "Project.toml"))
            end
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
            @test occursin("Artifact printed: Hello, World!", app_output)
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

            if is_julia_1_6 || is_julia_1_9
                # Julia 1.6: Issue #706 "Cannot locate artifact 'LLVMExtra'" on 1.6 so remove.
                # Julia 1.9: There's no GitHub Issue, but it seems we hit a similar problem.
                @test_skip false
            else
                @test occursin("LLVMExtra path: ok!", app_output)
            end
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
        if is_gha_ci && is_julia_1_12
            # On Julia 1.12, `incremental=false` is currently broken when doing `create_library()`.
            # 1.12: No GitHub issue yet.
            # So, for now, we skip the `incremental=false` tests on Julia 1.12 when doing `create_library()`.
            # But ONLY on GHA (GitHub Actions).
            # On PkgEval, we do run these tests. This is intentional - we want PkgEval to
            # detect regressions, as well as fixes for those regressions.
            @warn "[GHA CI] This is Julia $(VERSION.major).$(VERSION.minor); skipping incremental=false test when doing `create_library()` due to known bug: issue TODO (for 1.12)"
            @test_skip false
        else
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
        if is_gha_ci && is_julia_1_12
            # On Julia 1.12, `incremental=false` is currently broken when doing `create_library()`.
            # 1.12: No GitHub issue yet.
            # So, for now, we skip the `incremental=false` tests on Julia 1.12 when doing `create_library()`.
            # But ONLY on GHA (GitHub Actions).
            # On PkgEval, we do run these tests. This is intentional - we want PkgEval to
            # detect regressions, as well as fixes for those regressions.
            @warn "This is Julia $(VERSION.major).$(VERSION.minor); skipping incremental=false test when doing `create_library()` due to known bug: issue TODO (for 1.12)"
            @test_skip false
        else
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
end
