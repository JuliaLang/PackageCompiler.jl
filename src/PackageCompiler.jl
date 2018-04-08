__precompile__()
module PackageCompiler


# TODO: remove once Julia v0.7 is released
const julia_v07 = VERSION > v"0.7-"
if julia_v07
    using Libdl
    import Sys: iswindows, isunix, isapple
    const contains07 = contains
else
    const iswindows = is_windows
    const isunix = is_unix
    const isapple = is_apple
    contains07(str, reg) = ismatch(reg, str)
end

using SnoopCompile

iswindows() && using WinRPM


include("static_julia.jl")
include("api.jl")
include("snooping.jl")
include("system_image.jl")
include("bootstrapping.jl")

const sysimage_binaries = (
    "sys.o", "sys.$(Libdl.dlext)", "sys.ji", "inference.o", "inference.ji"
)


function copy_system_image(src, dest, ignore_missing = false)
    for file in sysimage_binaries
        # backup
        srcfile = joinpath(src, file)
        destfile = joinpath(dest, file)
        if !isfile(srcfile)
            ignore_missing && continue
            error("No file: $srcfile")
        end
        if isfile(destfile)
            if isfile(destfile * ".backup")
                rm(destfile * ".backup", force = true)
            end
            mv(destfile, destfile * ".backup", remove_destination = true)
        end
        info("Copying system image: $srcfile to $destfile")
        cp(srcfile, destfile, remove_destination = true)
    end
end

julia_cpu_target(x) = error("CPU target needs to be a string or `nothing`")
julia_cpu_target(x::String) = x # TODO match against available targets
function julia_cpu_target(::Void)
    replace(Base.julia_cmd().exec[2], "-C", "")
end


"""
Reverts a forced compilation of the system image.
This will restore any previously backed up system image files, or
build a new, clean system image
"""
function revert(debug = false)
    syspath = default_sysimg_path(debug)
    sysimg_backup = dirname(get_backup!(debug))
    copy_system_image(sysimg_backup, syspath)
end

function get_root_dir(path)
    path, name = splitdir(path)
    if isempty(name)
        return splitdir(path)[2]
    else
        name
    end
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

"""
    compile_package(packages...; kw_args...)

with packages being either a string naming a package, or a tuple (package_name, precompile_file).
If no precompile file is given, it will use the packages runtests.jl, which is a good canditate
for figuring out what functions to compile!
"""
function compile_package(packages...; kw_args...)
    args = map(packages) do package
        # If no explicit path to a seperate precompile file, use runtests
        isa(package, String) && return (package, "test/runtests.jl")
        isa(package, Tuple{String, String}) && return package
        error("Unrecognized package. Use `packagename::String`, or (packagename::String, rel_path_to_testfile::String). Found: $package")
    end
    compile_package(args...; kw_args...)
end

"""
    compile_package(packages::Tuple{String, String}...; force = false, reuse = false, debug = false)

Compile a list of packages. Each package comes as a tuple of `(package_name, precompile_file)`
where the precompile file should contain all function calls, that should get compiled into the system image.
Usually the runtests.jl file is a good candidate, since it should run all important functions of a package.
"""
function compile_package(packages::Tuple{String, String}...; force = false, reuse = false, debug = false)
    userimg = sysimg_folder("precompile.jl")
    if !reuse
        snoop_userimg(userimg, packages...)
    end
    !isfile(userimg) && reuse && error("Nothing to reuse. Please run `compile_package(reuse = true)`")
    image_path = sysimg_folder()
    build_sysimg(image_path, userimg)
    imgfile = joinpath(image_path, "sys.$(Libdl.dlext)")
    syspath = joinpath(default_sysimg_path(debug), "sys.$(Libdl.dlext)")
    if force
        try
            backup = syspath * ".packagecompiler_backup"
            isfile(backup) || mv(syspath, backup)
            cp(imgfile, syspath)
            info(
                "Replaced system image successfully. Next start of julia will load the newly compiled system image.
                If you encounter any errors with the new julia image, try `PackageCompiler.revert([debug = false])`"
            )
        catch e
            warn("An error has occured while replacing sysimg files:")
            warn(e)
            info("Recovering old system image from backup")
            # if any file is missing in default system image, revert!
            if !isfile(syspath)
                info("$syspath missing. Reverting!")
                revert(debug)
            end
        end
    else
        info("""
            Not replacing system image.
            You can start julia with julia -J $(imgfile) to load the compiled files.
        """)
    end
    imgfile
end

function __init__()
    if Base.julia_cmd().exec[2] != "-Cnative"
        warn("Your Julia system image is not compiled natively for this CPU architecture.
        Please run `PackageCompiler.force_native_image!()` for optimal Julia performance"
        )
    end
end

export compile_package, revert, force_native_image!, executable_ext, build_executable
export stop_log_bootstrap, bootstrap, log_bootstrap

end # module
