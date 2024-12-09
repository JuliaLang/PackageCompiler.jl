# This testset makes sure that the `examples/MyLib` example does not bitrot.

if Sys.iswindows()
    @info "Skipping the examples/MyLib test on Windows"
    @test_skip false
    # TODO: Figure out how to get this testset to work on Windows.
else
    rootdir_testdir = @__DIR__
    rootdir = dirname(rootdir_testdir)
    rootdir_examples = joinpath(rootdir, "examples")
    rootdir_examples_MyLib = joinpath(rootdir_examples, "MyLib")

    run_julia_code = (project, code; env = ENV) -> begin
        julia_binary = Base.julia_cmd()[1]
        env2 = copy(env)
        env2["JULIA_PROJECT"] = project
        cmd = `$(julia_binary) --startup-file=no -e "$(code)"`
        return run(setenv(cmd, env2))
    end
    run_julia_script = (project, scriptfile; env = ENV) -> begin
        julia_binary = Base.julia_cmd()[1]
        env2 = copy(env)
        env2["JULIA_PROJECT"] = project
        cmd = `$(julia_binary) --startup-file=no "$(scriptfile)"`
        return run(setenv(cmd, env2))
    end

    mktempdir() do mytmp
        # The PackageCompiler.jl source code directory might be read-only. So let's copy
        # examples/MyLib to a temp directory so that we can write stuff to it.
        MyLib_tmp = joinpath(mytmp, "MyLib")
        cp(rootdir_examples_MyLib, MyLib_tmp)

        cd(MyLib_tmp) do
            # Go into MyLib_tmp/build/ and dev this copy of PackageCompiler.jl
            run_julia_code("./build", """
                import Pkg
                Pkg.develop(; path = "$(rootdir)")
            """)

            # Instantiate and precompile the `MyLib/` and `MyLib/build/` environments.
            run_julia_code(".", "import Pkg; Pkg.instantiate(); Pkg.precompile()")
            run_julia_code("./build", "import Pkg; Pkg.instantiate(); Pkg.precompile()")

            # We don't want to assume that the machine running the tests has `make` installed
            # and available in the PATH. Therefore, we just run the relevant commands directly.

            # build-library
            run_julia_script("./build", "build/build.jl")

            # build-executable
            CC = PackageCompiler.get_compiler_cmd()
            TARGET = joinpath(MyLib_tmp, "MyLibCompiled")
            INCLUDE_DIR = joinpath(TARGET, "include")
            cmd = `$(CC) my_application.c -o $(TARGET)/my_application.out -I$(INCLUDE_DIR) -L$(TARGET)/lib -ljulia -lmylib`
            run(cmd)

            # Run `./my_application.out`
            env2 = copy(ENV)
            if Sys.isapple()
                env2["DYLD_FALLBACK_LIBRARY_PATH"] = "./MyLibCompiled/lib/:./MyLibCompiled/lib/julia/"
            else
                env2["LD_LIBRARY_PATH"] = "./MyLibCompiled/lib/"
            end
            cmd = `$(TARGET)/my_application.out`
            @test success(run(setenv(cmd, env2)))
            observed_str = strip(read(setenv(cmd, env2), String))
            expected_str = "Incremented count: 4 (Cint)\nIncremented value: 4"
            @test observed_str == expected_str
        end


    end

end # if-elseif-else-end
