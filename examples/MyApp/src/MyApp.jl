module MyApp

using Example
using HelloWorldC_jll
using Pkg.Artifacts
using Distributed


fooifier_path() = joinpath(artifact"fooifier", "bin", "fooifier" * (Sys.iswindows() ? ".exe" : ""))

function julia_main()
    try
        real_main()
    catch
        Base.invokelatest(Base.display_error, Base.catch_stack())
        return 1
    end
    return 0
end

function is_crayons_loaded()
    Base.PkgId(Base.UUID("a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f"), "Crayons") in keys(Base.loaded_modules)
end

function real_main()
    @show ARGS
    @show Base.PROGRAM_FILE
    @show DEPOT_PATH
    @show LOAD_PATH
    @show pwd()
    @show Base.active_project()
    @show Sys.BINDIR

    @show Base.JLOptions().opt_level
    @show Base.JLOptions().nthreads
    @show Base.JLOptions().check_bounds

    display(Base.loaded_modules)
    println()

    println("Running a jll package:")
    HelloWorldC_jll.hello_world() do x
        println("HelloWorld artifact at $(realpath(x))")
        run(`$x`)
    end
    println()

    @show is_crayons_loaded()

    println("Running the artifact")
    res = read(`$(fooifier_path()) 5 10`, String)
    println("The result of 2*5^2 - 10 == $res")

    @show unsafe_string(Base.JLOptions().image_file)
    @show Example.domath(5)
    @show sin(0.0)

    if nworkers() != 4
        addprocs(4)
        @eval @everywhere using MyApp
    end
   
    n = @distributed (+) for i = 1:20000000
        1
    end
    println("n = $n")
    # TODO: Code loading for distributed is currently only
    # really possible by shipping a Project.toml.  
    # @eval @everywhere using Example
    # @everywhere println(Example.domath(3))
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    real_main()
end

end # module
