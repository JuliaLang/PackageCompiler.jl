module MyApp

using Example
using HelloWorldC_jll
using Pkg.Artifacts

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

function real_main()
    @show ARGS
    @show Base.PROGRAM_FILE
    @show DEPOT_PATH
    @show LOAD_PATH
    @show pwd()
    @show Base.active_project()
    @show Threads.nthreads()
    @show Sys.BINDIR
    display(Base.loaded_modules)
    println()

    println("Running a jll package:")
    HelloWorldC_jll.hello_world() do x
        println("HelloWorld artifact at $(realpath(x))")
        run(`$x`)
    end
    println()

    println("Running the artifact")
    res = read(`$(fooifier_path()) 5 10`, String)
    println("The result of 2*5^2 - 10 == $res")

    @show unsafe_string(Base.JLOptions().image_file)
    @show Example.domath(5)
    @show sin(0.0)
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    real_main()
end

end # module
