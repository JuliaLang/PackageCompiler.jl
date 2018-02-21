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
    static_julia(juliaprog::String; kw_args...)

compiles the Julia file at path `juliaprog` with keyword arguments:

    cprog = nothing           C program to compile (required only when building an executable; if not provided a minimal driver program is used)
    builddir = "builddir"     directory used for building, either absolute or relative to the Julia program directory (default: "builddir")
    juliaprog_basename        basename for the built artifacts

    verbose                   increase verbosity
    quiet                     suppress non-error messages
    clean                     delete build directory

    autodeps                  automatically build required dependencies
    object                    build object file
    shared                    build shared library
    executable                build executable file
    julialibs                 sync Julia libraries to builddir

    sysimage <file>           start up with the given system image file
    compile {yes|no|all|min}  enable or disable JIT compiler, or request exhaustive compilation
    cpu_target <target>       limit usage of CPU features up to <target>
    optimize {0,1,2,3}        set optimization level (type: Int64)
    debug {0,1,2}             set debugging information level (type: Int64)
    inline {yes|no}           control whether inlining is permitted
    check_bounds {yes|no}     emit bounds checks always or never
    math_mode {ieee,fast}     set floating point optimizations
    depwarn {yes|no|error}    set syntax and method deprecation warnings

    cc                        system C compiler
"""
function static_julia(
        juliaprog;
        cprog = nothing, builddir = "builddir", juliaprog_basename = splitext(basename(juliaprog))[1],
        verbose = false, quiet = false, clean = false,
        autodeps = false, object = false, shared = false, executable = false, julialibs = false,
    	sysimage = nothing, compile = nothing, cpu_target = nothing,
    	optimize = nothing, debug = nothing, inline = nothing,
    	check_bounds = nothing, math_mode = nothing, depwarn = nothing,
    	cc = system_compiler()
    )

    verbose && quiet && (quiet = false)

    if autodeps
        executable && (shared = true)
        shared && (object = true)
    end

    juliaprog = abspath(juliaprog)
    isfile(juliaprog) || error("Cannot find file:\n  \"$juliaprog\"")
    quiet || println("Julia program file:\n  \"$juliaprog\"")
    if executable
        cprog = cprog == nothing ? joinpath(@__DIR__, "..", "examples", "program.c") : abspath(cprog)
        isfile(cprog) || error("Cannot find file:\n  \"$cprog\"")
        quiet || println("C program file:\n  \"$cprog\"")
    end

    cd(dirname(juliaprog))

    builddir = abspath(builddir)
    quiet || println("Build directory:\n  \"$builddir\"")

    if !any([clean, object, shared, executable, julialibs])
        quiet || println("Nothing to do")
        return
    end

    if clean
        if isdir(builddir)
            verbose && println("Delete build directory")
            rm(builddir, recursive=true)
        else
            verbose && println("Build directory does not exist, nothing to delete")
        end
    end

    if !any([object, shared, executable, julialibs])
        quiet || println("All done")
        return
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

    o_file = juliaprog_basename * ".o"
    s_file = juliaprog_basename * ".$(Libdl.dlext)"
    e_file = juliaprog_basename * executable_ext()

    object && build_object(
        juliaprog, builddir, o_file, verbose,
        sysimage, compile, cpu_target, optimize, debug, inline, check_bounds,
        math_mode, depwarn
    )

    shared && build_shared(s_file, joinpath(builddir, o_file), verbose, optimize, debug)

    executable && build_executable(s_file, e_file, cprog, verbose, optimize, debug)

    julialibs && sync_julia_files(verbose)

    quiet || println("All done")
end

# TODO: avoid calling "julia-config.jl" in future
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

function build_object(
        juliaprog, builddir, o_file, verbose,
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
    builddir_esc = escape_string(builddir)
    if julia_v07
        iswindows() && (juliaprog = replace(juliaprog, "\\", "\\\\"))
        expr = "Base.init_depot_path() # initialize package depots
        Base.init_load_path() # initialize location of site-packages
        empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
        push!(Base.LOAD_CACHE_PATH, abspath(\"$builddir_esc\")) # enable usage of precompiled files
        include(\"$juliaprog\") # include Julia program file
        empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
    else
        iswindows() && (juliaprog = replace(juliaprog, "\\", "\\\\"))
        expr = "empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
        push!(Base.LOAD_CACHE_PATH, abspath(\"$builddir_esc\")) # enable usage of precompiled files
        include(\"$juliaprog\") # include Julia program file
        empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
    end
    isdir(builddir) || mkpath(builddir)
    command = `$julia_cmd -e $expr`
    verbose && println("Build module image files \".ji\" in directory \"$builddir\":\n  $command")
    run(command)
    command = `$julia_cmd --output-o $(joinpath(builddir, o_file)) -e $expr`
    verbose && println("Build object file \"$o_file\" in directory \"$builddir\":\n  $command")
    run(command)
end

function build_shared(s_file, o_file, verbose, optimize, debug)
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

function build_executable(s_file, e_file, cprog, verbose, optimize, debug)
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
            append!(libfiles, joinpath.(dir, filter(x -> endswith(x, dlext) && !startswith(x, "sys"), readdir(dir))))
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
