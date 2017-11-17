__precompile__()
module PackageCompiler

using SnoopCompile

include("build_sysimg.jl")

const sysimage_binaries = (
    "sys.o", "sys.$(Libdl.dlext)", "sys.ji", "inference.o", "inference.ji"
)

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
    if all(x-> isfile(joinpath(sysimg_backup, x)), sysimage_binaries) # we have a backup
        for file in sysimage_binaries
            # backup
            bfile = joinpath(sysimg_backup, file)
            if isfile(bfile)
                sfile = joinpath(dirname(syspath), file)
                isfile(sfile) && mv(sfile, sfile*".old", remove_destination = true)
                mv(bfile, sfile, remove_destination = false)
            else
                warn("No backup of $file found")
            end
        end
    else
        warn("No backup found but restoring. Need to build a new system image from scratch")
        sysimg_backup = joinpath(@__DIR__, "..", "sysimg_backup") # build directly into backup
        isdir(sysimg_backup) || mkdir(sysimg_backup)
        build_sysimg(joinpath(sysimg_backup, "sys"))
        # now we should have a backup.
        # make sure that we have all files to not end up with an endless recursion!
        if all(x-> isfile(joinpath(sysimg_backup, x)), sysimage_binaries)
            revert(debug)
        else
            error("Revert went wrong")
        end
    end
end

function get_root_dir(path)
    path, name = splitdir(path)
    if isempty(name)
        return splitdir(path)[2]
    else
        name
    end
end


function compile_package(package, force = false, reuse = false; debug = false)
    realpath = if ispath(package)
        normpath(abspath(package))
    else
        Pkg.dir(package)
    end
    testroot = joinpath(realpath, "test")
    sysimg_tmp = normpath(joinpath(@__DIR__, "..", "sysimg_tmp", get_root_dir(realpath)))
    sysimg_backup = joinpath(@__DIR__, "..", "sysimg_backup")
    isdir(sysimg_backup) || mkdir(sysimg_tmp)
    isdir(sysimg_tmp) || mkdir(sysimg_tmp)
    precompile_file = joinpath(sysimg_tmp, "precompile.jl")
    snoop(
        joinpath(testroot, "runtests.jl"),
        precompile_file,
        joinpath(sysimg_tmp, "snooped.csv"),
        reuse
    )
    build_sysimg(joinpath(sysimg_tmp, "sys"), "native", precompile_file)
    if force
        try
            syspath = default_sysimg_path(debug)
            for file in sysimage_binaries
                # backup
                bfile = joinpath(sysimg_backup, file)
                sfile = joinpath(dirname(syspath), file)
                if !isfile(bfile) # use the one that is already there
                    mv(sfile, bfile, remove_destination = true)
                else
                    mv(sfile, sfile*".old", remove_destination = true) # remove so we don't overwrite (seems to be problematic on windows)
                end
                mv(joinpath(sysimg_tmp, file), sfile, remove_destination = false)
            end
        catch e
            warn("An error has occured while replacing sysimg files:")
            warn(e)
            info("Recovering old system image from backup")
            revert(debug)
        end
    else
        info("""
            Not replacing system image.
            You can start julia with julia -J $(joinpath(sysimg_tmp, "sys")) to load the compiled files.
        """)
    end
end

end # module
