module PackageCompiler

using SnoopCompile

function snoop(path, compilationfile)
    mktempdir() do tmpfolder
        csv = joinpath(tmpfolder, "precompile.csv")
        # Snoop compiler can't handle the path as a variable, so we just create a file

        open(joinpath(tmpfolder, "snoopy.jl"), "w") do io
            println(io, "mod = include(\"$(escape_string(path))\")")
            println(io, "mod.run()")
            println(io, "mod")
        end
        cd(tmpfolder)
        SnoopCompile.@snoop csv begin
            include("snoopy.jl")
        end
        data = SnoopCompile.read(csv)
        pc = SnoopCompile.parcel(reverse!(data[2]))
        mod = include(path) # just get the module name
        modsym = Symbol(mod)
        modstr = String(modsym)
        delims = r"([\{\} \n\(\),])_([\{\} \n\(\),])"
        open(compilationfile, "w") do io
            for (k, v) in pc
                k in (:unknown, modsym) && continue
                println(io, "using $k")
                eval(:(using $k))
            end
            for (k, v) in pc
                k == modsym && continue
                println(k)
                for ln in v
                    if !contains(ln, modstr)
                        # replace `_` for free parameters, which print out a warning otherwise
                        ln = replace(ln, delims, s"\1XXX\2")
                        # only print out valid lines
                        try
                            eval(parse(ln))
                            println(io, ln)
                        catch e
                            warn(e)
                        end
                    end
                end
            end
        end
    end
end


include(joinpath(JULIA_HOME, Base.DATAROOTDIR,"julia", "build_sysimg.jl"))

function compile(file; force = false)
    build_sysimg(default_sysimg_path(), "native", file, force = force)
end

function revert(file; force = false)
    build_sysimg(force = true)
end



end # module
