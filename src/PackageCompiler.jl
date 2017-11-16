__precompile__()
module PackageCompiler

using SnoopCompile

include("build_sysimg.jl")

function snoop(path, compilationfile)
    cd(@__DIR__)
    mktempdir() do tmpfolder
        csv = joinpath(homedir(), "test.csv") #joinpath(tmpfolder, "precompile.csv")
        # Snoop compiler can't handle the path as a variable, so we just create a file
        open(joinpath(tmpfolder, "snoopy.jl"), "w") do io
            println(io, "include(\"$(escape_string(path))\")")
        end
        cd(tmpfolder)
        SnoopCompile.@snoop csv begin
            include("snoopy.jl")
        end
        data = SnoopCompile.read(csv)
        pc = SnoopCompile.parcel(reverse!(data[2]))
        delims = r"([\{\} \n\(\),])_([\{\} \n\(\),])"
        tmp_mod = eval(:(module $(gensym()) end))
        open(compilationfile, "w") do io
            for (k, v) in pc
                k == :unknown && continue
                println(k)
                try
                    eval(tmp_mod, :(using $k))
                    println(io, "using $k")
                catch e
                    warn(e)
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
                        warn(e)
                    end
                end
            end
        end
    end
    cd(@__DIR__)
end


function compile(file; force = false)
    build_sysimg(default_sysimg_path(), "native", file, force = force)
end

function revert(file; force = false)
    build_sysimg(force = true)
end

function compile_package(package, force = false)
    realpath = if ispath(package)
        normpath(abspath(package))
    else
        Pkg.dir(package)
    end
    testroot = joinpath(realpath, "test")
    precompile_file = joinpath(testroot, "precompile.jl")
    snoop(joinpath(testroot, "runtests.jl"), precompile_file)
    build_sysimg(default_sysimg_path(), "native", precompile_file, force = force)
end

end # module
