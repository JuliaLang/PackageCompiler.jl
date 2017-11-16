__precompile__()
module PackageCompiler

using SnoopCompile

include("build_sysimg.jl")

function snoop(path, compilationfile, reuse)
    cd(@__DIR__)
    csv = "precompile.csv"
    # Snoop compiler can't handle the path as a variable, so we just create a file
    if !reuse
        open(joinpath("snoopy.jl"), "w") do io
            println(io, "include(\"$(escape_string(path))\")")
        end
        SnoopCompile.@snoop csv begin
            include("snoopy.jl")
        end
    end
    data = SnoopCompile.read(csv)
    pc = SnoopCompile.parcel(reverse!(data[2]))
    delims = r"([\{\} \n\(\),])_([\{\} \n\(\),])"
    tmp_mod = eval(:(module $(gensym()) end))
    open(compilationfile, "w") do io
        for (k, v) in pc
            k == :unknown && continue
            try
                eval(tmp_mod, :(using $k))
                println(io, "using $k")
                info("using $k")
            catch e
                println("Module not found: $k")
            end
        end
        for (k, v) in pc
            for ln in v
                # replace `_` for free parameters, which print out a warning otherwise
                ln = replace(ln, delims, s"\1XXX\2")
                # only print out valid lines
                # TODO figure out why some precompile statements have undefined free variables in there
                try
                    eval(tmp_mod, parse(ln))
                    println(io, ln)
                catch e
                    warn("Not emitted: ", ln)
                end
            end
        end
    end
end

function revert()
    build_sysimg(force = true)
end

function compile_package(package, force = false, reuse = false)
    realpath = if ispath(package)
        normpath(abspath(package))
    else
        Pkg.dir(package)
    end
    testroot = joinpath(realpath, "test")
    precompile_file = joinpath(testroot, "precompile.jl")
    snoop(joinpath(testroot, "runtests.jl"), precompile_file, reuse)
    build_sysimg(default_sysimg_path(), "native", precompile_file, force = force)
end

end # module
