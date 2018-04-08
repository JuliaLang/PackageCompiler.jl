function default_sysimg_path(debug = false)
    ext = debug ? "sys-debug" : "sys"
    if is_unix()
        dirname(splitext(Libdl.dlpath(ext))[1])
    else
        joinpath(dirname(JULIA_HOME), "lib", "julia")
    end
end

function compile_system_image(sysimg_path, cpu_target = nothing; debug = false)
    # Enter base and setup some useful paths
    base_dir = dirname(Base.find_source_file("sysimg.jl"))
    cd(base_dir) do
        # This can probably get merged with build_object.
        # At some point, I will need to understand build_object a bit better before doing that move, though!
        julia_cmd = Base.julia_cmd()
        julia = julia_cmd.exec[1]
        cpu_target = if cpu_target == nothing
            replace(julia_cmd.exec[2], "-C", "")
        else
            cpu_target
        end
        cc = system_compiler()
        # Ensure we have write-permissions to wherever we're trying to write to
        try
            touch("$sysimg_path.ji")
        catch
            err_msg =  "Unable to modify $sysimg_path.ji, ensure parent directory exists "
            err_msg *= "and is writable; absolute paths work best.)"
            error(err_msg)
        end
        # Start by building inference.{ji,o}
        inference_path = joinpath(dirname(sysimg_path), "inference")
        info("Building inference.o")
        info("$julia -O3 -C $cpu_target --output-ji $inference_path.ji --output-o $inference_path.o coreimg.jl")
        run(`$julia -O3 -C $cpu_target --output-ji $inference_path.ji --output-o $inference_path.o coreimg.jl`)

        # Bootstrap off of that to create sys.{ji,o}
        info("Building sys.o")
        info("$julia -O3 -C $cpu_target --output-ji $sysimg_path.ji --output-o $sysimg_path.o -J $inference_path.ji --startup-file=no sysimg.jl")
        run(`$julia -O3 -C $cpu_target --output-ji $sysimg_path.ji --output-o $sysimg_path.o -J $inference_path.ji --startup-file=no sysimg.jl`)

        build_shared(
            "$sysimg_path.$(Libdl.dlext)", "$sysimg_path.o",
            true, nothing, debug ? 2 : nothing, nothing
        )
    end
end

"""
Returns the system image file stored in the backup folder.
If there is no backup, this function will automatically generate a system image
in the backup folder.
"""
function get_backup!(debug, cpu_target = nothing)
    target = julia_cpu_target(cpu_target)
    sysimg_backup = sysimgbackup_folder(target)
    isdir(sysimg_backup) || mkpath(sysimg_backup)
    if !all(x-> isfile(joinpath(sysimg_backup, x)), sysimage_binaries) # we have a backup
        compile_system_image(joinpath(sysimg_backup, "sys"), target; debug = debug)
    end
    return joinpath(sysimg_backup, "sys.$(Libdl.dlext)")
end

|
