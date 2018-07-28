# This code is derived from `julia-config.jl` (part of Julia) and should be kept aligned with it.

threadingOn() = ccall(:jl_threading_enabled, Cint, ()) != 0

function shell_escape(str)
    if julia_v07
        str = replace(str, "'" => "'\''")
    else
        str = replace(str, "'", "'\''")
    end
    return "'$str'"
end

function libDir()
    return if ccall(:jl_is_debugbuild, Cint, ()) != 0
        dirname(abspath(Libdl.dlpath("libjulia-debug")))
    else
        dirname(abspath(Libdl.dlpath("libjulia")))
    end
end

if julia_v07
    private_libDir() = abspath(Sys.BINDIR, Base.PRIVATE_LIBDIR)
else
    private_libDir() = abspath(JULIA_HOME, Base.PRIVATE_LIBDIR)
end

function includeDir()
    if julia_v07
        return abspath(Sys.BINDIR, Base.INCLUDEDIR, "julia")
    else
        return abspath(JULIA_HOME, Base.INCLUDEDIR, "julia")
    end
end

function ldflags()
    fl = "-L$(shell_escape(libDir()))"
    if iswindows()
        fl = fl * " -Wl,--stack,8388608"
    elseif islinux()
        fl = fl * " -Wl,--export-dynamic"
    end
    return fl
end

function ldlibs()
    libname = if ccall(:jl_is_debugbuild, Cint, ()) != 0
        "julia-debug"
    else
        "julia"
    end
    if isunix()
        return "-Wl,-rpath,$(shell_escape(libDir())) -Wl,-rpath,$(shell_escape(private_libDir())) -l$libname"
    else
        return "-l$libname -lopenlibm"
    end
end

function cflags()
    flags = IOBuffer()
    print(flags, "-std=gnu99")
    include = shell_escape(includeDir())
    print(flags, " -I", include)
    if threadingOn()
        print(flags, " -DJULIA_ENABLE_THREADING=1")
    end
    if isunix()
        print(flags, " -fPIC")
    end
    return String(take!(flags))
end

function allflags()
    return "$(cflags()) $(ldflags()) $(ldlibs())"
end
