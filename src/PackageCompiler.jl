module PackageCompiler

using Pkg, Serialization, Libdl, UUIDs
using Pkg: TOML,  Operations, Types


include("compiler_flags.jl")
include("static_julia.jl")
include("api.jl")
include("snooping.jl")
include("system_image.jl")
include("pkg.jl")
include("incremental.jl")


const sysimage_binaries = ("sys.$(Libdl.dlext)",)

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
            mv(destfile, destfile * ".backup", force = true)
        end
        @info "Copying system image: $srcfile to $destfile"
        cp(srcfile, destfile, force = true)
    end
end

julia_cpu_target(x) = error("CPU target needs to be a string or `nothing`")
julia_cpu_target(x::String) = x # TODO: match against available targets
function julia_cpu_target(::Nothing)
    replace(Base.julia_cmd().exec[2], "-C" => "")
end

"""
Reverts a forced compilation of the system image.
This will restore any previously backed up system image files, or
build a new, clean system image.
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

with packages being either a string naming a package, or a tuple `(package_name, precompile_file)`.
If no precompile file is given, it will use the packages `runtests.jl`, which is a good canditate
for figuring out what functions to compile!
"""
function compile_package(packages...; kw_args...)
    args = map(packages) do package
        # If no explicit path to a seperate precompile file, use runtests
        isa(package, String) && return (package, "test/runtests.jl")
        isa(package, Tuple{String, String}) && return package
        error("Unrecognized package. Use `packagename::String`, or `(packagename::String, rel_path_to_testfile::String)`. Found: `$package`")
    end
    compile_package(args...; kw_args...)
end

"""
    compile_package(
        packages::Tuple{String, String}...;
        force = false, reuse = false, debug = false, cpu_target = nothing,
        additional_packages = Symbol[]
    )

Compile a list of packages. Each package comes as a tuple of `(package_name, precompile_file)`
where the precompile file should contain all function calls, that should get compiled into the system image.
Usually the `runtests.jl` file is a good candidate, since it should run all important functions of a package.
You can pass `additional_packages` a vector of symbols with package names, to help AOT compiling
uninstalled, recursive dependencies of `packages`. Look at `compile_incremental` to
use a toml instead.
"""
function compile_package(
        packages::Tuple{String, String}...;
        force = false, reuse = false, debug = false,
        cpu_target = nothing, verbose = false
    )
    userimg = sysimg_folder("precompile.jl")
    if !reuse
        # TODO that's a pretty weak way to check that it's not a path...
        ispackage = all(x-> !occursin(Base.Filesystem.path_separator, x), first.(packages))
        isruntests = all(x-> x == "test/runtests.jl", last.(packages))
        if ispackage && isruntests
            snoop_packages(Symbol.(first.(packages))...; file = userimg)
        else
            ispackage || @warn "Giving path to package deprecated. Use Package name!"
            isruntests || @warn "Giving a snoopfile is deprecated. Use runtests from package!"
        end
    end
    !isfile(userimg) && reuse && error("Nothing to reuse. Please run `compile_package(reuse = true)`")
    image_path = sysimg_folder()
    build_sysimg(image_path, userimg, cpu_target=cpu_target, verbose = verbose)
    imgfile = joinpath(image_path, "sys.$(Libdl.dlext)")
    syspath = joinpath(default_sysimg_path(debug), "sys.$(Libdl.dlext)")
    if force
        try
            backup = syspath * ".packagecompiler_backup"
            isfile(backup) || mv(syspath, backup)
            cp(imgfile, syspath)
            @info """
            Replaced system image successfully. Next start of julia will load the newly compiled system image.
            If you encounter any errors with the new julia image, try `PackageCompiler.revert([debug = false])`.
            """
        catch e
            @warn "An error occured while replacing sysimg files:" error = e
            @info "Recovering old system image from backup"
            # if any file is missing in default system image, revert!
            if !isfile(syspath)
                @info "$syspath missing. Reverting!"
                revert(debug)
            end
        end
    else
        @info """
        Not replacing system image.
        You can start julia with $(`julia -J $imgfile`) at a posix shell to load the compiled files.
        """
    end
    imgfile
end



export compile_package, revert, force_native_image!, executable_ext, build_executable, build_shared_lib, static_julia, compile_incremental

end # module
