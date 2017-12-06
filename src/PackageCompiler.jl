__precompile__()
module PackageCompiler

using SnoopCompile

include("build_sysimg.jl")

const sysimage_binaries = (
    "sys.o", "sys.$(Libdl.dlext)", "sys.ji", "inference.o", "inference.ji"
)

function snoop(path, compilationfile, csv)
    cd(@__DIR__)
    # Snoop compiler can't handle the path as a variable, so we just create a file
    open(joinpath("snoopy.jl"), "w") do io
        println(io, "include(\"$(escape_string(path))\")")
    end
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
                # TODO figure out the actual problems and why snoop compile emits invalid code
                try
                    parse(ln) # parse to make sure expression is parsing without error
                    # wrap in try catch to catch problematic code emitted by SnoopCompile
                    # without interupting the whole precompilation
                    # (usually, SnoopCompile emits 1% erroring statements)
                    println(io, "try\n    ", ln, "\nend")
                catch e
                    warn("Not emitted because code couldn't parse: ", ln)
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
        isdir(sysimg_backup) || mkpath(sysimg_backup)
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

function snoop_package(package::String, rel_snoop_file, sysimg_tmp, reuse)
    precompile_file = joinpath(sysimg_tmp, "precompile.jl")

end

function sysimg_folder(files...)
    base_path = normpath(abspath(joinpath(@__DIR__, "..", "sysimg")))
    isdir(base_path) || mkpath(base_path)
    normpath(abspath(joinpath(base_path, files...)))
end

function sysimgbackup_folder(files...)
    backup = sysimg_folder("backup")
    isdir(backup) || mkpath(backup)
    sysimg_folder("backup", files...)
end


function package_folder(package...)
    packages = normpath(abspath(joinpath(@__DIR__, "..", "packages")))
    isdir(packages) || mkpath(packages)
    normpath(abspath(joinpath(packages, package...)))
end


function compile_package(packages...; kw_args...)
    args = map(packages) do package
        # If no explicit path to a seperate precompile file, use runtests
        isa(package, String) && return (package, "test/runtests.jl")
        isa(package, Tuple{String, String}) && return package
        error("Unrecognized package. Use `packagename::String`, or (packagename::String, rel_path_to_testfile::String). Found: $package")
    end
    compile_package(args...; kw_args...)
end

function snoop_userimg(userimg, packages::Tuple{String, String}...)
    snooped_precompiles = map(packages) do package_snoopfile
        package, snoopfile = package_snoopfile
        abs_package_path = if ispath(package)
            normpath(abspath(package))
        else
            Pkg.dir(package)
        end
        file2snoop = normpath(abspath(joinpath(abs_package_path, snoopfile)))
        package = package_folder(get_root_dir(abs_package_path))
        isdir(package) || mkpath(package)
        precompile_file = joinpath(package, "precompile.jl")
        snoop(
            file2snoop,
            precompile_file,
            joinpath(package, "snooped.csv")
        )
        precompile_file
    end
    open(userimg, "w") do io
        for path in snooped_precompiles
            write(io, open(read, path))
            println(io)
        end
    end
    userimg
end

function compile_package(packages::Tuple{String, String}...; force = false, reuse = false, debug = false)
    userimg = sysimg_folder("precompile.jl")
    if !reuse
        snoop_userimg(userimg, packages...)
    end
    !isfile(userimg) && reuse && error("Nothing to reuse. Please run `compile_package(reuse = true)`")
    image_path = sysimg_folder("sys")
    build_sysimg(image_path, "native", userimg)
    if force
        try
            replace_jl_sysimg(debug)
            info(
                "Replaced system image successfully. Next start of julia will load the newly compiled system image.
                If you encounter any errors with the new julia image, try `PackageCompiler.revert([debug = false])`"
            )
        catch e
            warn("An error has occured while replacing sysimg files:")
            warn(e)
            info("Recovering old system image from backup")
            revert(debug)
        end
    else
        info("""
            Not replacing system image.
            You can start julia with julia -J $(image_path) to load the compiled files.
        """)
    end
end


function replace_jl_sysimg(debug = false)
    syspath = default_sysimg_path(debug)
    for file in sysimage_binaries
        # backup
        bfile = sysimgbackup_folder(file)
        sfile = joinpath(dirname(syspath), file)
        if !isfile(bfile) # use the one that is already there
            mv(sfile, bfile, remove_destination = true)
        else
            mv(sfile, sfile*".old", remove_destination = true) # remove so we don't overwrite (seems to be problematic on windows)
        end
        mv(joinpath(sysimg_tmp, file), sfile, remove_destination = false)
    end
end


end # module
