const depsfile = joinpath(@__DIR__, "..", "deps", "deps.jl")

if isfile(depsfile)
    include(depsfile)
    gccworks = try
        success(`$gcc -v`)
    catch
        false
    end
    if !gccworks
        error("GCC wasn't found. Please make sure that gcc is on the path and run Pkg.build(\"PackageCompiler\")")
    end
else
    error("Package wasn't build correctly. Please run Pkg.build(\"PackageCompiler\")")
end

system_compiler() = gcc
bitness_flag() = Int == Int32 ? "-m32" : "-m64"
executable_ext() = (iswindows() ? ".exe" : "")

function mingw_dir(folders...)
    joinpath(
        WinRPM.installdir, "usr", "$(Sys.ARCH)-w64-mingw32",
        "sys-root", "mingw", folders...
    )
end

"""
    julia_compile(julia_program::String; kw_args...)

compiles the julia file at path `julia_program` with keyword arguments:

    cprog = nothing           C program to compile (required only when building an executable; if not provided a minimal driver program is used)
    builddir = "builddir"     directory used for building
    julia_program_basename    basename for the compiled artifacts

    autodeps                  automatically build required dependencies
    object                    build object file
    shared                    build shared library
    executable                build executable file (Bool)
    julialibs                 sync Julia libraries to builddir

    verbose                   increase verbosity
    quiet                     suppress non-error messages
    clean                     delete builddir


    sysimage <file>           start up with the given system image file
    compile {yes|no|all|min}  enable or disable JIT compiler, or request exhaustive compilation
    cpu_target <target>       limit usage of CPU features up to <target>
    optimize {0,1,2,3}        set optimization level (type: Int64)
    debug {0,1,2}             set debugging information level (type: Int64)
    inline {yes|no}           control whether inlining is permitted
    check_bounds {yes|no}     emit bounds checks always or never
    math_mode {ieee,fast}     set floating point optimizations
    depwarn {yes|no|error}    set syntax and method deprecation warnings


"""
function julia_compile(
        julia_program;
        julia_program_basename = splitext(basename(julia_program))[1],
        cprog = nothing, builddir = "builddir",
        verbose = false, quiet = false, clean = false, sysimage = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing,
        debug = nothing, inline = nothing, check_bounds = nothing,
        math_mode = nothing, depwarn = nothing, autodeps = false,
        object = false, shared = false, executable = true, julialibs = true,
        cc = system_compiler()
    )

    verbose && quiet && (quiet = false)

    if autodeps
        executable && (shared = true)
        shared && (object = true)
    end

    julia_program = abspath(julia_program)
    isfile(julia_program) || error("Cannot find file:\n  \"$julia_program\"")
    quiet || println("Julia program file:\n  \"$julia_program\"")
    if executable
        cprog = cprog == nothing ? joinpath(@__DIR__, "..", "examples", "program.c") : abspath(cprog)
        isfile(cprog) || error("Cannot find file:\n  \"$cprog\"")
        quiet || println("C program file:\n  \"$cprog\"")
    end

    cd(dirname(julia_program))

    builddir = abspath(builddir)
    quiet || println("Build directory:\n  \"$builddir\"")

    if clean
        if isdir(builddir)
            verbose && println("Delete build directory")
            rm(builddir, recursive=true)
        else
            verbose && println("Build directory does not exist, nothing to delete")
        end
    end

    if !isdir(builddir)
        verbose && println("Make build directory")
        mkpath(builddir)
    end

    if pwd() != builddir
        verbose && println("Change to build directory")
        cd(builddir)
    else
        verbose && println("Already in build directory")
    end

    o_file = julia_program_basename * ".o"
    s_file = julia_program_basename * ".$(Libdl.dlext)"
    e_file = julia_program_basename * executable_ext()
    tmp_dir = "tmp_v$VERSION"

    object && build_object(
        julia_program, tmp_dir, o_file, verbose,
        sysimage, compile, cpu_target, optimize, debug, inline, check_bounds,
        math_mode, depwarn
    )

    shared && build_shared(s_file, joinpath(tmp_dir, o_file), verbose, optimize, debug)

    executable && compile_executable(s_file, e_file, cprog, verbose, optimize, debug)

    julialibs && sync_julia_files(verbose)

end


function julia_flags(optimize, debug)
    if julia_v07
        command = `$(Base.julia_cmd()) --startup-file=no $(joinpath(dirname(Sys.BINDIR), "share", "julia", "julia-config.jl"))`
        flags = `$(Base.shell_split(read(\`$command --allflags\`, String)))`
        optimize == nothing || (flags = `$flags -O$optimize`)
        debug != 2 || (flags = `$flags -g`)
        return flags
    else
        command = `$(Base.julia_cmd()) --startup-file=no $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl"))`
        cflags = `$(Base.shell_split(readstring(\`$command --cflags\`)))`
        optimize == nothing || (cflags = `$cflags -O$optimize`)
        debug != 2 || (cflags = `$cflags -g`)
        ldflags = `$(Base.shell_split(readstring(\`$command --ldflags\`)))`
        ldlibs = `$(Base.shell_split(readstring(\`$command --ldlibs\`)))`
        return `$cflags $ldflags $ldlibs`
    end
end


function build_shared(s_file, o_file, verbose = false, optimize, debug)
    cc = system_compiler()
    bitness = bitness_flag()
    flags = julia_flags(optimize, debug)
    command = `$cc $bitness -shared -o $s_file $o_file $flags`
    if isapple()
        command = `$command -Wl,-install_name,@rpath/$s_file`
    elseif iswindows()
        command = `$command -Wl,--export-all-symbols`
    end
    verbose && println("Build shared library \"$s_file\" in build directory:\n  $command")
    run(command)
end


function compile_executable(s_file, e_file, cprog, verbose = false, optimize, debug)
    bitness = bitness_flag()
    cc = system_compiler()
    flags = julia_flags(optimize, debug)
    command = `$cc $bitness -DJULIAC_PROGRAM_LIBNAME=\"$s_file\" -o $e_file $cprog $s_file $flags`
    if iswindows()
        RPMbindir = PackageCompiler.mingw_dir("bin")
        incdir = PackageCompiler.mingw_dir("include")
        push!(Base.Libdl.DL_LOAD_PATH, RPMbindir) # TODO does this need to be reversed?
        ENV["PATH"] = ENV["PATH"] * ";" * RPMbindir
        command = `$command -I$incdir`
    elseif isapple()
        command = `$command -Wl,-rpath,@executable_path`
    else
        command = `$command -Wl,-rpath,\$ORIGIN`
    end
    verbose && println("Building executable \"$e_file\" in build directory:\n  $command")
    run(command)
end

function build_object(
        julia_program, builddir, o_file, verbose,
        sysimage, compile, cpu_target, optimize, debug, inline, check_bounds,
        math_mode, depwarn
    )
    julia_cmd = `$(Base.julia_cmd())`
    if length(julia_cmd.exec) != 5 || !all(startswith.(julia_cmd.exec[2:5], ["-C", "-J", "--compile", "--depwarn"]))
        error("Unexpected format of \"Base.julia_cmd()\", you may be using an incompatible version of Julia")
    end
    sysimage == nothing || (julia_cmd.exec[3] = "-J$sysimage")
    push!(julia_cmd.exec, "--startup-file=no")
    compile == nothing || (julia_cmd.exec[4] = "--compile=$compile")
    cpu_target == nothing || (julia_cmd.exec[2] = "-C$cpu_target")
    optimize == nothing || push!(julia_cmd.exec, "-O$optimize")
    debug == nothing || push!(julia_cmd.exec, "-g$debug")
    inline == nothing || push!(julia_cmd.exec, "--inline=$inline")
    check_bounds == nothing || push!(julia_cmd.exec, "--check-bounds=$check_bounds")
    math_mode == nothing || push!(julia_cmd.exec, "--math-mode=$math_mode")
    depwarn == nothing || (julia_cmd.exec[5] = "--depwarn=$depwarn")
    if julia_v07
        iswindows() && (julia_program = replace(julia_program, "\\", "\\\\"))
        expr = "Base.init_depot_path() # initialize package depots
        Base.init_load_path() # initialize location of site-packages
        empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
        push!(Base.LOAD_CACHE_PATH, abspath(\"$builddir\")) # enable usage of precompiled files
        include(\"$julia_program\") # include \"julia_program\" file
        empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
    else
        iswindows() && (julia_program = replace(julia_program, "\\", "\\\\"))
        expr = "empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
        push!(Base.LOAD_CACHE_PATH, abspath(\"$builddir\")) # enable usage of precompiled files
        include(\"$julia_program\") # include \"julia_program\" file
        empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
    end

    isdir(builddir) || mkpath(builddir)
    command = `$julia_cmd -e $expr`
    verbose && println("Build module image files \".ji\" in subdirectory \"$builddir\":\n  $command")
    run(command)
    command = `$julia_cmd --output-o $(joinpath(builddir, o_file)) -e $expr`
    verbose && println("Build object file \"$o_file\" in subdirectory \"$builddir\":\n  $command")
    run(command)
end

function sync_julia_files(verbose)
    # TODO: these should probably be emitted from julia-config also:
    if julia_v07
        shlibdir = iswindows() ? Sys.BINDIR : abspath(Sys.BINDIR, Base.LIBDIR)
        private_shlibdir = abspath(Sys.BINDIR, Base.PRIVATE_LIBDIR)
    else
        shlibdir = iswindows() ? JULIA_HOME : abspath(JULIA_HOME, Base.LIBDIR)
        private_shlibdir = abspath(JULIA_HOME, Base.PRIVATE_LIBDIR)
    end

    verbose && println("Sync Julia libraries to build directory:")
    libfiles = String[]
    dlext = "." * Libdl.dlext
    for dir in (shlibdir, private_shlibdir)
        if iswindows() || isapple()
            append!(libfiles, joinpath.(dir, filter(x -> endswith(x, dlext), readdir(dir))))
        else
            append!(libfiles, joinpath.(dir, filter(x -> contains07(x, r"^lib.+\.so(?:\.\d+)*$"), readdir(dir))))
        end
    end
    sync = false
    for src in libfiles
        contains07(src, r"debug") && continue
        dst = basename(src)
        if filesize(src) != filesize(dst) || ctime(src) > ctime(dst) || mtime(src) > mtime(dst)
            verbose && println("  $dst")
            cp(src, dst, remove_destination=true, follow_symlinks=false)
            sync = true
        end
    end
    sync || verbose && println("  none")
end
