function default_sysimg_path(debug = false)
    ext = debug ? "sys-debug" : "sys"
    if is_unix()
        dirname(splitext(Libdl.dlpath(ext))[1])
    else
        joinpath(dirname(JULIA_HOME), "lib", "julia")
    end
end

function compile_system_image(sysimg_path, cpu_target; debug = false)
    # Enter base and setup some useful paths
    base_dir = dirname(Base.find_source_file("sysimg.jl"))
    cd(base_dir) do
        # This can probably get merged with build_object.
        # At some point, I will need to understand build_object a bit better before doing that move, though!
        julia = Base.julia_cmd().exec[1]
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
        info("$julia -C $cpu_target --output-ji $inference_path.ji --output-o $inference_path.o coreimg.jl")
        run(`$julia -C $cpu_target --output-ji $inference_path.ji --output-o $inference_path.o coreimg.jl`)

        # Bootstrap off of that to create sys.{ji,o}
        info("Building sys.o")
        info("$julia -C $cpu_target --output-ji $sysimg_path.ji --output-o $sysimg_path.o -J $inference_path.ji --startup-file=no sysimg.jl")
        run(`$julia -C $cpu_target --output-ji $sysimg_path.ji --output-o $sysimg_path.o -J $inference_path.ji --startup-file=no sysimg.jl`)

        build_shared("$sysimg_path.$(Libdl.dlext)", "$sysimg_path.o",
                     true, nothing, (if debug 2 else nothing end))
    end
end
