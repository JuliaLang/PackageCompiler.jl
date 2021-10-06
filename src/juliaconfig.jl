# adopted from https://github.com/JuliaLang/julia/blob/release-0.6/contrib/julia-config.jl

isdebugbuild() = ccall(:jl_is_debugbuild, Cint, ()) != 0 

function shell_escape(str)
    str = replace(str, "'" => "'\''")
    return "'$str'"
end

function julia_libdir()
    libname = isdebugbuild() ? "libjulia-debug" : 
                               "libjulia"
    return dirname(abspath(Libdl.dlpath(libname)))
end

function julia_private_libdir()
    if Base.DARWIN_FRAMEWORK # taken from Libdl tests
        if ccall(:jl_is_debugbuild, Cint, ()) != 0
            dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME * "_debug")))
        else
            joinpath(dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME))),"Frameworks")
        end
    elseif ccall(:jl_is_debugbuild, Cint, ()) != 0
        dirname(abspath(Libdl.dlpath("libjulia-internal-debug")))
    else
        dirname(abspath(Libdl.dlpath("libjulia-internal")))
    end
end

julia_includedir() = abspath(Sys.BINDIR, Base.INCLUDEDIR, "julia")

function ldflags()
    fl = "-L$(shell_escape(julia_libdir())) -L$(shell_escape(julia_private_libdir()))"
    if Sys.iswindows()
        fl = fl * " -Wl,--stack,8388608"
        fl = fl * " -Wl,--export-all-symbols"
    elseif Sys.islinux()
        fl = fl * " -Wl,--export-dynamic"
    end
    return fl
end

function ldlibs()
    libnames = isdebugbuild() ? "-ljulia-debug -ljulia-internal-debug" : 
                                "-ljulia       -ljulia-internal"
    if Sys.islinux()
        return "-Wl,-rpath-link,$(shell_escape(julia_libdir())) -Wl,-rpath-link,$(shell_escape(julia_private_libdir())) $libnames"
    elseif Sys.iswindows()
        return "$libnames -lopenlibm"
    else
        return "$libnames"
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

function rpath_executable()
    Sys.iswindows() ? `` :
    Sys.isapple()   ? `-Wl,-rpath,'@executable_path/../lib' -Wl,-rpath,'@executable_path/../lib/julia'` :
                      `-Wl,-rpath,\$ORIGIN/../lib:\$ORIGIN/../lib/julia`
end

function rpath_sysimage()
    Sys.iswindows() ? `` :
    Sys.isapple()   ? `-Wl,-rpath,'@executable_path' -Wl,-rpath,'@executable_path/julia'` :
                      `-Wl,-rpath,\$ORIGIN:\$ORIGIN/julia`
end
