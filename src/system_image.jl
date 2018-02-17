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
        julia = "julia"
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

        link_sysimg(sysimg_path, cc, debug)
    end
end

# Link sys.o into sys.$(dlext)
function link_sysimg(sysimg_path, cc = system_compiler(), debug = false)

    julia_libdir = dirname(Libdl.dlpath(debug ? "libjulia-debug" : "libjulia"))

    FLAGS = ["-L$julia_libdir"]

    push!(FLAGS, "-shared")
    push!(FLAGS, debug ? "-ljulia-debug" : "-ljulia")
    if is_windows()
        push!(FLAGS, "-lssp")
    end

    sysimg_file = "$sysimg_path.$(Libdl.dlext)"
    info("Linking sys.$(Libdl.dlext)")
    info("$cc $(join(FLAGS, ' ')) -o $sysimg_file $sysimg_path.o")
    # Windows has difficulties overwriting a file in use so we first link to a temp file
    run(`$cc $FLAGS -o $sysimg_file $sysimg_path.o`)
end
