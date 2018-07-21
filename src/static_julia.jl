const depsfile = normpath(@__DIR__, "..", "deps", "deps.jl")

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

system_compiler = gcc
executable_ext = iswindows() ? ".exe" : ""

function mingw_dir(folders...)
    joinpath(
        WinRPM.installdir, "usr", "$(Sys.ARCH)-w64-mingw32",
        "sys-root", "mingw", folders...
    )
end

"""
    static_julia(juliaprog::String; kw_args...)

compiles the Julia file at path `juliaprog` with keyword arguments:

    cprog                     C program to compile (required only when building an executable; if not provided a minimal driver program is used)
    verbose                   increase verbosity
    quiet                     suppress non-error messages
    builddir                  build directory
    outname                   output files basename
    clean                     remove build directory
    autodeps                  automatically build required dependencies
    object                    build object file
    shared                    build shared library
    executable                build executable file
    rmtemp                    remove temporary build files
    julialibs                 copy Julia libraries to build directory
    sysimage <file>           start up with the given system image file
    precompiled {yes|no}      use precompiled code from system image if available
    compilecache {yes|no}     enable/disable incremental precompilation of modules
    home <dir>                set location of `julia` executable
    startup_file {yes|no}     load ~/.juliarc.jl
    handle_signals {yes|no}   enable or disable Julia's default signal handlers
    compile {yes|no|all|min}  enable or disable JIT compiler, or request exhaustive compilation
    cpu_target <target>       limit usage of CPU features up to <target> (forces --precompiled=no)
    optimize {0,1,2,3}        set the optimization level
    debug <level>             enable / set the level of debug info generation
    inline {yes|no}           control whether inlining is permitted
    check_bounds {yes|no}     emit bounds checks always or never
    math_mode {ieee,fast}     disallow or enable unsafe floating point optimizations
    depwarn {yes|no|error}    enable or disable syntax and method deprecation warnings
    cc                        system C compiler
    cc_flags <flags>          pass custom flags to the system C compiler when building a shared library or executable
"""
function static_julia(
        juliaprog;
        cprog = normpath(@__DIR__, "..", "examples", "program.c"), verbose = false, quiet = false,
        builddir = "builddir", outname = splitext(basename(juliaprog))[1], clean = false,
        autodeps = false, object = false, shared = false, executable = false, rmtemp = false, julialibs = false,
        sysimage = nothing, precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing,
        cc = system_compiler, cc_flags = nothing
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
        cprog = abspath(cprog)
        isfile(cprog) || error("Cannot find file:\n  \"$cprog\"")
        quiet || println("C program file:\n  \"$cprog\"")
    end

    builddir = abspath(builddir)
    quiet || println("Build directory:\n  \"$builddir\"")

    if !any([clean, object, shared, executable, rmtemp, julialibs])
        quiet || println("Nothing to do")
        return
    end

    if clean
        if isdir(builddir)
            verbose && println("Remove build directory")
            rm(builddir, recursive=true)
        else
            verbose && println("Build directory does not exist")
        end
    end

    if !any([object, shared, executable, rmtemp, julialibs])
        quiet || println("All done")
        return
    end

    if !isdir(builddir)
        verbose && println("Make build directory")
        mkpath(builddir)
    end

    o_file = joinpath(builddir, outname * (julia_v07 ? ".a" : ".o"))
    s_file = joinpath(builddir, outname * ".$(Libdl.dlext)")
    e_file = joinpath(builddir, outname * executable_ext)

    object && build_object(
        juliaprog, o_file, verbose,
        sysimage, precompiled, compilecache, home, startup_file, handle_signals,
        compile, cpu_target, optimize, debug, inline, check_bounds, math_mode, depwarn
    )

    shared && build_shared(s_file, o_file, verbose, optimize, debug, cc, cc_flags)

    executable && build_executable(e_file, cprog, s_file, verbose, optimize, debug, cc, cc_flags)

    rmtemp && remove_temporary_files(builddir, verbose)

    julialibs && copy_julia_libs(builddir, verbose)

    quiet || println("All done")
end

# TODO: avoid calling "julia-config.jl" in future
function julia_flags(optimize, debug, cc_flags)
    bitness_flag = Sys.ARCH == :aarch64 ? `` : Int == Int32 ? "-m32" : "-m64"
    if julia_v07
        command = `$(Base.julia_cmd()) --startup-file=no $(normpath(Sys.BINDIR, "..", "share", "julia", "julia-config.jl"))`
        allflags = Base.shell_split(read(`$command --allflags`, String))
        allflags = `$allflags $bitness_flag`
        optimize == nothing || (allflags = `$allflags -O$optimize`)
        debug == 2 && (allflags = `$allflags -g`)
        cc_flags == nothing || isempty(cc_flags) || (allflags = `$allflags $cc_flags`)
        return allflags
    else
        command = `$(Base.julia_cmd()) --startup-file=no $(normpath(JULIA_HOME, "..", "share", "julia", "julia-config.jl"))`
        cflags = Base.shell_split(readstring(`$command --cflags`))
        optimize == nothing || (cflags = `$cflags -O$optimize`)
        debug == 2 && (cflags = `$cflags -g`)
        cc_flags == nothing || isempty(cc_flags) || (cflags = `$cflags $cc_flags`)
        ldflags = Base.shell_split(readstring(`$command --ldflags`))
        ldlibs = Base.shell_split(readstring(`$command --ldlibs`))
        return `$bitness_flag $cflags $ldflags $ldlibs`
    end
end

function build_julia_cmd(
        sysimage, precompiled, compilecache, home, startup_file, handle_signals,
        compile, cpu_target, optimize, debug, inline, check_bounds, math_mode, depwarn
    )
    # TODO: `precompiled` and `compilecache` may be removed in future, see: https://github.com/JuliaLang/PackageCompiler.jl/issues/47
    precompiled == nothing && cpu_target != nothing && (precompiled = "no")
    compilecache == nothing && (compilecache = "no")
    # TODO: `startup_file` may be removed in future with `julia-compile`, see: https://github.com/JuliaLang/julia/issues/15864
    startup_file == nothing && (startup_file = "no")
    julia_cmd = `$(Base.julia_cmd())`
    if length(julia_cmd.exec) != 5 || !all(startswith.(julia_cmd.exec[2:5], ["-C", "-J", "--compile", "--depwarn"]))
        error("Unexpected format of \"Base.julia_cmd()\", you may be using an incompatible version of Julia")
    end
    sysimage == nothing || (julia_cmd.exec[3] = "-J$sysimage")
    precompiled == nothing || push!(julia_cmd.exec, "--precompiled=$precompiled")
    compilecache == nothing || push!(julia_cmd.exec, "--compilecache=$compilecache")
    home == nothing || push!(julia_cmd.exec, "-H=$home")
    startup_file == nothing || push!(julia_cmd.exec, "--startup-file=$startup_file")
    handle_signals == nothing || push!(julia_cmd.exec, "--handle-signals=$handle_signals")
    compile == nothing || (julia_cmd.exec[4] = "--compile=$compile")
    cpu_target == nothing || (julia_cmd.exec[2] = "-C$cpu_target")
    optimize == nothing || push!(julia_cmd.exec, "-O$optimize")
    debug == nothing || push!(julia_cmd.exec, "-g$debug")
    inline == nothing || push!(julia_cmd.exec, "--inline=$inline")
    check_bounds == nothing || push!(julia_cmd.exec, "--check-bounds=$check_bounds")
    math_mode == nothing || push!(julia_cmd.exec, "--math-mode=$math_mode")
    depwarn == nothing || (julia_cmd.exec[5] = "--depwarn=$depwarn")
    julia_cmd
end

function build_object(
        juliaprog, o_file, verbose,
        sysimage, precompiled, compilecache, home, startup_file, handle_signals,
        compile, cpu_target, optimize, debug, inline, check_bounds, math_mode, depwarn
    )
    julia_cmd = build_julia_cmd(
        sysimage, precompiled, compilecache, home, startup_file, handle_signals,
        compile, cpu_target, optimize, debug, inline, check_bounds, math_mode, depwarn
    )
    cache_dir = joinpath(dirname(o_file), "cache_ji_v$VERSION")
    iswindows() && ((juliaprog, cache_dir) = replace.((juliaprog, cache_dir), "\\", "\\\\"))
    if julia_v07
        expr = "
  Base.init_depot_path() # initialize package depots
  Base.init_load_path() # initialize location of site-packages
  Sys.__init__();  # Needed to find built-in Modules.
  Base.__init__();
  include(\"$juliaprog\") # include Julia program file"
    else
        expr = "
  empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
  push!(Base.LOAD_CACHE_PATH, \"$cache_dir\") # enable usage of precompiled files
  Sys.__init__(); Base.early_init(); # JULIA_HOME is not defined, initializing manually
  include(\"$juliaprog\") # include Julia program file
  empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
    end
    if compilecache == "yes"
        command = `$julia_cmd -e $expr`
        verbose && println("Build \".ji\" local cache:\n  $command")
        run(command)
    end
    command = `$julia_cmd --output-o $o_file -e $expr`
    verbose && println("Build object file \"$o_file\":\n  $command")
    run(command)
end

function build_shared(s_file, o_file, verbose, optimize, debug, cc, cc_flags)
    command = `$cc -shared -o $s_file $o_file $(julia_flags(optimize, debug, cc_flags))`
    if isapple()
        command = `$command -Wl,-install_name,@rpath/$(basename(s_file))`
    elseif iswindows()
        command = `$command -Wl,--export-all-symbols`
    end
    # Prevent compiler from stripping all symbols from the shared lib.
    julia_v07 && (command = `$command -Wl,-$(isapple() ? "all_load" : "whole-archive")`)
    verbose && println("Build shared library \"$s_file\":\n  $command")
    run(command)
end

function build_executable(e_file, cprog, s_file, verbose, optimize, debug, cc, cc_flags)
    command = `$cc -DJULIAC_PROGRAM_LIBNAME=\"$(basename(s_file))\" -o $e_file $cprog $s_file $(julia_flags(optimize, debug, cc_flags))`
    if iswindows()
        RPMbindir = mingw_dir("bin")
        incdir = mingw_dir("include")
        push!(Base.Libdl.DL_LOAD_PATH, RPMbindir) # TODO does this need to be reversed?
        ENV["PATH"] = ENV["PATH"] * ";" * RPMbindir
        command = `$command -I$incdir`
    elseif isapple()
        command = `$command -Wl,-rpath,@executable_path`
    else
        command = `$command -Wl,-rpath,\$ORIGIN`
    end
    if Int == Int32
        # TODO this was added because of an error with julia on win32 that suggested this line.
        # Seems to work, not sure if it's correct
        command = `$command -march=pentium4`
    end
    verbose && println("Build executable \"$e_file\":\n  $command")
    run(command)
end

function remove_temporary_files(builddir, verbose)
    verbose && println("Remove temporary files:")
    remove = false
    for tmp in filter(x -> endswith(x, ".o") || startswith(x, "cache_ji_v"), readdir(builddir))
        verbose && println("  $tmp")
        rm(joinpath(builddir, tmp), recursive=true)
        remove = true
    end
    verbose && !remove && println("  none")
end

function copy_julia_libs(builddir, verbose)
    # TODO: these should probably be emitted from julia-config also:
    if julia_v07
        shlibdir = iswindows() ? Sys.BINDIR : joinpath(Sys.BINDIR, Base.LIBDIR)
        private_shlibdir = joinpath(Sys.BINDIR, Base.PRIVATE_LIBDIR)
    else
        shlibdir = iswindows() ? JULIA_HOME : joinpath(JULIA_HOME, Base.LIBDIR)
        private_shlibdir = joinpath(JULIA_HOME, Base.PRIVATE_LIBDIR)
    end
    verbose && println("Copy Julia libraries to build directory:")
    libfiles = String[]
    dlext = "." * Libdl.dlext
    for dir in (shlibdir, private_shlibdir)
        if iswindows() || isapple()
            append!(libfiles, joinpath.(dir, filter(x -> endswith(x, dlext) && !startswith(x, "sys"), readdir(dir))))
        else
            append!(libfiles, joinpath.(dir, filter(x -> contains07(x, r"^lib.+\.so(?:\.\d+)*$"), readdir(dir))))
        end
    end
    copy = false
    for src in libfiles
        contains07(src, r"debug") && continue
        dst = joinpath(builddir, basename(src))
        if filesize(src) != filesize(dst) || ctime(src) > ctime(dst) || mtime(src) > mtime(dst)
            verbose && println("  $(basename(src))")
            cp(src, dst, remove_destination=true, follow_symlinks=false)
            copy = true
        end
    end
    verbose && !copy && println("  none")
end
