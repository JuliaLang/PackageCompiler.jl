module MyApp

using Example
using HelloWorldC_jll
using Artifacts
using Distributed
using Random
if VERSION >= v"1.7.0"
    using LLVMExtra_jll
end

using micromamba_jll

const myrand = rand()

const outputo = begin
    o = Base.JLOptions().outputo
    o == C_NULL ? "ok" : unsafe_string(o)
end

fooifier_path() = joinpath(artifact"fooifier", "bin", "fooifier" * (Sys.iswindows() ? ".exe" : ""))

function julia_main()::Cint
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

    println("outputo: $outputo")

    # Check that the RNG is seeded during precompilation
    println("myrand: ", myrand == 0.0 ? "fail" : "ok")
    rand() # Check that RNG state is ok
    if nworkers() != 4
        addprocs(4)
        @eval @everywhere using MyApp
    end

    n = @distributed (+) for i = 1:20000000
        1
    end
    println("n = $n")
    @eval @everywhere using Example
    @everywhere println(Example.domath(3))

    if VERSION >= v"1.7.0"
        if isfile(LLVMExtra_jll.libLLVMExtra_path)
            println("LLVMExtra path: ok!")
        else
            println("LLVMExtra path: fail!")
        end
    end

    if isfile(micromamba_jll.micromamba_path)
        println("micromamba_jll path: ok!")
    else
        println("micromamba_jll path: fail!")
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    real_main()
end

# Used for testing
function second_main()::Cint
    println("Hello from second main")
    return 0
end

function wrong_return_type()
    return "oops"
end

function erroring()
    1 + "foo"
    return 0
end



end # module
