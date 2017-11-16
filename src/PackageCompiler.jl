__precompile__()
module PackageCompiler

using SnoopCompile

include("build_sysimg.jl")

function snoop(path, compilationfile, csv, reuse)
    cd(@__DIR__)
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

function clean_image(debug = false)
    build_sysimg(default_sysimg_path(debug), force = true)
end

function revert(debug = false)
    syspath = default_sysimg_path(debug)
    sysimg_backup = joinpath(@__DIR__, "..", "sysimg_backup")
    sysfiles = ("sys.o", "sys.so", "sys.ji", "inference.o", "inference.ji")
    if all(x-> isfile(joinpath(sysimg_backup, x)), sysfiles) # we have a backup
        for file in sysfiles
            # backup
            bfile = joinpath(sysimg_backup, file)
            if isfile(bfile)
                sfile = joinpath(dirname(syspath), file)
                isfile(sfile) && rm(sfile)
                mv(bfile, sfile)
            else
                warn("No backup of $file found")
            end
        end
    else
        warn("No backup found but restoring. Need to build a new system image from scratch")
        sysimg_backup = joinpath(@__DIR__, "..", "sysimg_backup") # build directly into backup
        build_sysimg(joinpath(sysimg_backup, "sys"))
        # now we should have a backup.
        # make sure that we have all files to not end up with an endless recursion!
        if all(x-> isfile(joinpath(sysimg_backup, x)), sysfiles)
            revert(debug)
        else
            error("Revert went wrong")
        end
    end
end

function compile_package(package, force = false, reuse = false; debug = false)
    realpath = if ispath(package)
        normpath(abspath(package))
    else
        Pkg.dir(package)
    end
    testroot = joinpath(realpath, "test")
    precompile_file = joinpath(testroot, "precompile.jl")
    sysimg_tmp = joinpath(@__DIR__, "..", "sysimg_tmp", basename(realpath))
    snoop(joinpath(testroot, "runtests.jl"), precompile_file, joinpath(sysimg_tmp, "snooped.csv"), reuse)
    !isdir(sysimg_tmp) && mkdir(sysimg_tmp)
    build_sysimg(joinpath(sysimg_tmp, "sys"), "native", precompile_file)
    sysimg_backup = joinpath(@__DIR__, "..", "sysimg_backup")
    if force
        try
            syspath = default_sysimg_path(debug)
            for file in ("sys.o", "sys.so", "sys.ji", "inference.o", "inference.ji")
                # backup
                bfile = joinpath(sysimg_backup, file)
                sfile = joinpath(dirname(syspath), file)
                if !isfile(bfile) # use the one that is already there
                    mv(sfile, bfile, remove_destination = true)
                else
                    rm(sfile) # remove so we don't overwrite (seems to be problematic on windows)
                end
                mv(joinpath(sysimg_tmp, file), sfile)
            end
        catch e
            warn("An error has occured while replacing sysimg files:")
            warn(e)
            info("Recovering old system image from backup")
            revert(debug)
        end
    else
        info("Not forcing system image. You can start julia with julia -J $(joinpath(sysimg_tmp, "sys")) to load the compiled files.")
    end
end

end # module
