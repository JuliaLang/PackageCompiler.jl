# adopted from https://github.com/JuliaLang/julia/blob/release-0.6/contrib/julia-config.jl

function shell_escape(str)
    str = replace(str, "'" => "'\''")
    return "'$str'"
end

function julia_libdir()
    return if ccall(:jl_is_debugbuild, Cint, ()) != 0
        dirname(abspath(Libdl.dlpath("libjulia-debug")))
    else
        dirname(abspath(Libdl.dlpath("libjulia")))
    end
end

function julia_private_libdir()
    @static if Sys.iswindows()
        return julia_libdir()
    else
        return abspath(Sys.BINDIR, Base.PRIVATE_LIBDIR)
    end
end

julia_includedir() = abspath(Sys.BINDIR, Base.INCLUDEDIR, "julia")

function ldflags()
    fl = "-L$(shell_escape(julia_libdir()))"
    if Sys.iswindows()
        fl = fl * " -Wl,--stack,8388608"
        fl = fl * " -Wl,--export-all-symbols"
    elseif Sys.islinux()
        fl = fl * " -Wl,--export-dynamic"
    end
    return fl
end

# TODO
function ldlibs(relative_path=nothing)
    libname = if ccall(:jl_is_debugbuild, Cint, ()) != 0
        "julia-debug"
    else
        "julia"
    end
    if Sys.islinux()
        return "-Wl,-rpath-link,$(shell_escape(julia_libdir())) -Wl,-rpath-link,$(shell_escape(julia_private_libdir())) -l$libname"
    elseif Sys.iswindows()
        return "-l$libname -lopenlibm"
    else
        return "-l$libname"
    end
end

function cflags()
    flags = IOBuffer()
    print(flags, "-std=gnu99")
    include = shell_escape(julia_includedir())
    print(flags, " -I", include)
    if Sys.isunix()
        print(flags, " -fPIC")
    end
    return String(take!(flags))
end

