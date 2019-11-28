module MyApp

using Example
using Pkg.Artifacts

socrates = joinpath(ensure_artifact_installed("socrates", joinpath(@__DIR__, "..", "Artifacts.toml")), 
                    "bin", "socrates")

Base.@ccallable function julia_main()::Cint
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
    println("Running an artifact:")
    run(`$socrates`)
    println()
    @show unsafe_string(Base.JLOptions().image_file)
    @show Example.domath(5)
    @show sin(0.0)
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    real_main()
end

end # module
