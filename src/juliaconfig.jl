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

# Detect if Julia is a local build (libraries in lib/ directly instead of lib/julia/)
function is_local_julia_build()
    lib_dir = julia_libdir()
    # In local builds, libLLVM is directly in lib/, not in lib/julia/
    return any(startswith(f, "libLLVM") for f in readdir(lib_dir))
end

function julia_private_libdir()
    if Base.DARWIN_FRAMEWORK # taken from Libdl tests
        if isdebugbuild() != 0
            dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME * "_debug")))
        else
            joinpath(dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME))),"Frameworks")
        end
    elseif isdebugbuild() != 0
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
        if VERSION >= v"1.11"
            # This should not really be necessary if users are using DLLEXPORT as required
            # on Windows in any compiled / init `.c` files, but we keep these flag for
            # backwards-compatibility on v1.11+ where it is mostly harmless now that LLVM
            # 16+ emits `-exclude-symbols` directives
            #
            # On Julia 1.10, users must annotate their code with DLLEXPORT for it to link,
            # since this flag would cause Julia to easily hit COFF symbol limits.
            #
            # (see https://github.com/JuliaLang/julia/pull/59736)
            fl = fl * " -Wl,--export-all-symbols"
        end
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
    print(flags, " -Werror-implicit-function-declaration")
    print(flags, " -O2 -std=gnu11")
    include = shell_escape(julia_includedir())
    print(flags, " -I", include)
    if Sys.isunix()
        print(flags, " -fPIC")
    end
    if Sys.iswindows()
        print(flags, " -municode")
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
