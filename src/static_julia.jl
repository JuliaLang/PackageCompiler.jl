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
    error("Package wasn't built correctly. Please run Pkg.build(\"PackageCompiler\")")
end

system_compiler = gcc
executable_ext = Sys.iswindows() ? ".exe" : ""

if Sys.iswindows()
    function run_PATH(cmd)
        bindir = dirname(cmd.exec[1])
        run(setenv(cmd, ["PATH=" * bindir * ";" * ENV["PATH"]]))
    end
else
    const run_PATH = run
end


"""
    static_julia(juliaprog::String; kw_args...)

compiles the Julia file at path `juliaprog` with keyword arguments:

    cprog                            C program to compile (required only when building an executable, if not provided a minimal driver program is used)
    verbose                          increase verbosity
    quiet                            suppress non-error messages
    builddir                         build directory
    outname                          output files basename
    snoopfile                        specify script calling functions to precompile
    clean                            remove build directory
    autodeps                         automatically build required dependencies
    object                           build object file
    shared                           build shared library
    init_shared                      add `init_jl_runtime` and `exit_jl_runtime` to shared library for runtime initialization
    executable                       build executable file
    rmtemp                           remove temporary build files
    copy_julialibs                   copy Julia libraries to build directory
    copy_files                       copy user-specified files to build directory (either `nothing` or a string array)
    release                          build in release mode, implies `-O3 -g0` unless otherwise specified
    Release                          perform a fully automated release build, equivalent to `-atjr`
    sysimage <file>                  start up with the given system image file
    home <dir>                       set location of `julia` executable
    startup_file {yes|no}            load `~/.julia/config/startup.jl`
    handle_signals {yes|no}          enable or disable Julia's default signal handlers
    sysimage_native_code {yes|no}    use native code from system image if available
    compiled_modules {yes|no}        enable or disable incremental precompilation of modules
    depwarn {yes|no|error}           enable or disable syntax and method deprecation warnings
    warn_overwrite {yes|no}          enable or disable method overwrite warnings
    compile {yes|no|all|min}         enable or disable JIT compiler, or request exhaustive compilation
    cpu_target <target>              limit usage of CPU features up to <target> (implies default `--sysimage_native_code=no`)
    optimize {0,1,2,3}               set the optimization level
    debug <level>                    enable / set the level of debug info generation
    inline {yes|no}                  control whether inlining is permitted
    check_bounds {yes|no}            emit bounds checks always or never
    math_mode {ieee,fast}            disallow or enable unsafe floating point optimizations
    cc                               system C compiler
    cc_flags <flags>                 pass custom flags to the system C compiler when building a shared library or executable (either `nothing` or a string array)
"""
function static_julia(
        juliaprog;
        cprog = nothing, verbose = false, quiet = false, builddir = nothing, outname = nothing, snoopfile = nothing,
        clean = false, autodeps = false, object = false, shared = false, init_shared = false, executable = false, rmtemp = false,
        copy_julialibs = false, copy_files = nothing, release = false, Release = false,
        sysimage = nothing, home = nothing, startup_file = nothing, handle_signals = nothing,
        sysimage_native_code = nothing, compiled_modules = nothing,
        depwarn = nothing, warn_overwrite = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing,
        cc = nothing, cc_flags = nothing
    )

    cprog == nothing && (cprog = normpath(@__DIR__, "..", "examples", "program.c"))
    builddir == nothing && (builddir = "builddir")
    outname == nothing && (outname = splitext(basename(juliaprog))[1])
    cc == nothing && (cc = system_compiler)

    verbose && quiet && (quiet = false)

    if Release
        autodeps = rmtemp = copy_julialibs = release = true
    end

    if autodeps
        executable && (shared = true)
        shared && (object = true)
    end

    if release
        optimize == nothing && (optimize = "3")
        debug == nothing && (debug = "0")
    end

    if juliaprog != nothing
        juliaprog = abspath(juliaprog)
        isfile(juliaprog) || error("Cannot find file: \"$juliaprog\"")
        quiet || println("Julia program file:\n  \"$juliaprog\"")
    end

    if executable
        cprog = abspath(cprog)
        isfile(cprog) || error("Cannot find file: \"$cprog\"")
        quiet || println("C program file:\n  \"$cprog\"")
    end

    builddir = abspath(builddir)
    quiet || println("Build directory:\n  \"$builddir\"")

    if [clean, object, shared, executable, rmtemp, copy_julialibs, copy_files] == [false, false, false, false, false, false, nothing]
        quiet || println("Nothing to do")
        return
    end

    if clean
        if isdir(builddir)
            verbose && println("Remove build directory")
            rm(builddir, recursive = true)
        else
            verbose && println("Build directory does not exist")
        end
    end

    if [object, shared, executable, rmtemp, copy_julialibs, copy_files] == [false, false, false, false, false, nothing]
        quiet || println("Clean completed")
        return
    end

    if !isdir(builddir)
        verbose && println("Make build directory")
        mkpath(builddir)
    end

    o_file = outname * ".a"
    s_file = outname * ".$(Libdl.dlext)"
    e_file = outname * executable_ext

    if object
        if snoopfile != nothing
            snoopfile = abspath(snoopfile)
            verbose && println("Executing snoopfile: \"$snoopfile\"")
            precompfile = joinpath(builddir, "precompiled.jl")
            snoop(nothing, nothing, snoopfile, precompfile)
            jlmain = joinpath(builddir, "julia_main.jl")
            open(jlmain, "w") do io
                # this file will get included via @eval Module() include(...)
                # but the juliaprog should be included in the main module
                juliaprog != nothing && println(io, "Base.include(Main, $(repr(relpath(juliaprog, builddir))))")
                println(io, "Base.include(@__MODULE__, $(repr(relpath(precompfile, builddir))))")
            end
            juliaprog = jlmain
        end
        build_object(
            juliaprog, o_file, builddir, verbose,
            sysimage, home, startup_file, handle_signals, sysimage_native_code, compiled_modules,
            depwarn, warn_overwrite, compile, cpu_target, optimize, debug, inline, check_bounds, math_mode
        )
    end

    shared && build_shared(s_file, o_file, init_shared, builddir, verbose, optimize, debug, cc, cc_flags)

    executable && build_exec(e_file, cprog, s_file, builddir, verbose, optimize, debug, cc, cc_flags)

    rmtemp && remove_temp_files(builddir, verbose)

    copy_julialibs && copy_julia_libs(builddir, verbose)

    copy_files != nothing && copy_files_array(copy_files, builddir, verbose, "Copy user-specified files to build directory:")

    quiet || println("All done")
end

function julia_flags(optimize, debug, cc_flags)
    allflags = Base.shell_split(PackageCompiler.allflags())
    bitness_flag = Sys.ARCH == :aarch64 ? `` : Int == Int32 ? "-m32" : "-m64"
    allflags = `$allflags $bitness_flag`
    optimize == nothing || (allflags = `$allflags -O$optimize`)
    debug == 2 && (allflags = `$allflags -g`)
    cc_flags == nothing || isempty(cc_flags) || (allflags = `$allflags $cc_flags`)
    allflags
end

function build_julia_cmd(
        sysimage, home, startup_file, handle_signals, sysimage_native_code, compiled_modules,
        depwarn, warn_overwrite, compile, cpu_target, optimize, debug, inline, check_bounds, math_mode
    )
    # TODO: `sysimage_native_code` and `compiled_modules` may be removed in future, see: https://github.com/JuliaLang/PackageCompiler.jl/issues/47
    sysimage_native_code == nothing && cpu_target != nothing && (sysimage_native_code = "no")
    compiled_modules == nothing && (compiled_modules = "no")
    # TODO: `startup_file` may be removed in future with `julia-compile`, see: https://github.com/JuliaLang/julia/issues/15864
    startup_file == nothing && (startup_file = "no")
    julia_cmd = `$(Base.julia_cmd())`
    function get_flag_idx(julia_cmd, flag_str)
        findfirst(f->(length(f) > length(flag_str) &&
                      f[1:length(flag_str)]==flag_str), julia_cmd.exec)
    end
    function set_flag(julia_cmd, flag_str, val)
        flag_idx = get_flag_idx(julia_cmd, flag_str)
        if flag_idx != nothing
            julia_cmd.exec[flag_idx] = "$flag_str$val"
        else
            push!(julia_cmd.exec, "$flag_str$val")
        end
    end
    sysimage == nothing || set_flag(julia_cmd, "-J", sysimage)
    home == nothing || set_flag(julia_cmd, "-H=", home)
    startup_file == nothing || set_flag(julia_cmd, "--startup-file=", startup_file)
    handle_signals == nothing || set_flag(julia_cmd, "--handle-signals=", handle_signals)
    sysimage_native_code == nothing || set_flag(julia_cmd, "--sysimage-native-code=", sysimage_native_code)
    compiled_modules == nothing || set_flag(julia_cmd, "--compiled-modules=", compiled_modules)
    depwarn == nothing || set_flag(julia_cmd, "--depwarn=", depwarn)
    warn_overwrite == nothing || set_flag(julia_cmd, "--warn-overwrite=", warn_overwrite)
    compile == nothing || set_flag(julia_cmd, "--compile=", compile)
    cpu_target == nothing || set_flag(julia_cmd, "-C", cpu_target)
    optimize == nothing || set_flag(julia_cmd, "-O", optimize)
    debug == nothing || set_flag(julia_cmd, "-g", debug)
    inline == nothing || set_flag(julia_cmd, "--inline=", inline)
    check_bounds == nothing || set_flag(julia_cmd, "--check-bounds=", check_bounds)
    math_mode == nothing || set_flag(julia_cmd, "--math-mode=", math_mode)
    # Disable incompatible flags
    set_flag(julia_cmd, "--code-coverage=", "none")

    julia_cmd
end

function build_object(
        juliaprog, o_file, builddir, verbose,
        sysimage, home, startup_file, handle_signals, sysimage_native_code, compiled_modules,
        depwarn, warn_overwrite, compile, cpu_target, optimize, debug, inline, check_bounds, math_mode
    )
    # TODO really refactor this :D
    build_object(
        juliaprog, o_file, builddir, verbose;
        sysimage = sysimage, startup_file = startup_file,
        handle_signals = handle_signals, sysimage_native_code = sysimage_native_code,
        compiled_modules = compiled_modules,
        depwarn = depwarn, warn_overwrite = warn_overwrite,
        compile = compile, cpu_target = cpu_target, optimize = optimize,
        debug_level = debug, inline = inline, check_bounds = check_bounds, math_mode = math_mode
    )
end

function build_object(
        juliaprog, o_file, builddir, verbose; julia_flags...
    )
    Sys.iswindows() && (juliaprog != nothing) && (juliaprog = replace(juliaprog, "\\" => "\\\\"))
    command = ExitHooksStart() * InitBase() * InitREPL()
    if juliaprog != nothing
        command *= Include(juliaprog)
    end
    command *= ExitHooksEnd()
    verbose && println("Build static library $(repr(o_file)):\n  $command")
    cd(builddir) do
        run_julia(
            command; julia_flags...,
            output_o = o_file, track_allocation = "none", code_coverage = "none"
        )
    end
end

function build_shared(s_file, o_file, init_shared, builddir, verbose, optimize, debug, cc, cc_flags)
    if init_shared
        i_file = joinpath(builddir, "lib_init.c")
        open(i_file, "w") do io
            print(io, """
		// Julia headers (for initialization and gc commands)
		#include "uv.h"
		#include "julia.h"
		void init_jl_runtime() // alternate name for jl_init_with_image, with hardcoded library name
		{
		    // JULIAC_PROGRAM_LIBNAME defined on command-line for compilation
		    const char rel_libname[] = JULIAC_PROGRAM_LIBNAME;
		    jl_init_with_image(NULL, rel_libname);
		}
		void exit_jl_runtime(int retcode) // alternate name for jl_atexit_hook
		{
		    jl_atexit_hook(retcode);
		}
		"""
            )
        end
        i_file = `$i_file`
    else
        i_file = ``
    end
    # Prevent compiler from stripping all symbols from the shared lib.
    if Sys.isapple()
        o_file = `-Wl,-all_load $o_file`
    else
        o_file = `-Wl,--whole-archive $o_file -Wl,--no-whole-archive`
    end
    command = `$cc -shared -DJULIAC_PROGRAM_LIBNAME=\"$s_file\" -o $s_file $o_file $i_file $(julia_flags(optimize, debug, cc_flags))`
    if Sys.isapple()
        command = `$command -Wl,-install_name,@rpath/$s_file`
    elseif Sys.iswindows()
        command = `$command -Wl,--export-all-symbols`
    end
    verbose && println("Build shared library $(repr(s_file)):\n  $command")
    cd(builddir) do
        run_PATH(command)
    end
end

function build_exec(e_file, cprog, s_file, builddir, verbose, optimize, debug, cc, cc_flags)
    command = `$cc -DJULIAC_PROGRAM_LIBNAME=\"$s_file\" -o $e_file $cprog $s_file $(julia_flags(optimize, debug, cc_flags))`
    if Sys.iswindows()
        # functionality doesn't readily exist on this platform
    elseif Sys.isapple()
        command = `$command -Wl,-rpath,@executable_path`
    else
        command = `$command -Wl,-rpath,\$ORIGIN`
    end
    if Int == Int32
        # TODO: this was added because of an error with julia on win32 that suggested this line, it seems to work but I'm not sure if it's correct
        command = `$command -march=pentium4`
    end
    verbose && println("Build executable $(repr(e_file)):\n  $command")
    cd(builddir) do
        run_PATH(command)
    end
end

function remove_temp_files(builddir, verbose)
    verbose && println("Remove temporary files:")
    remove = false
    for tmp in filter(x -> endswith(x, ".a") || startswith(x, "cache_ji_v"), readdir(builddir))
        verbose && println("  $tmp")
        rm(joinpath(builddir, tmp), recursive = true)
        remove = true
    end
    verbose && !remove && println("  none")
end

function copy_files_array(files_array, builddir, verbose, message)
    verbose && println(message)
    copy = false
    for src in files_array
        isfile(src) || error("Cannot find file: \"$src\"")
        dst = joinpath(builddir, basename(src))
        if filesize(src) != filesize(dst) || ctime(src) > ctime(dst) || mtime(src) > mtime(dst)
            verbose && println("  $(basename(src))")
            cp(src, dst, force = true, follow_symlinks = false)
            copy = true
        end
    end
    verbose && !copy && println("  none")
end

function copy_julia_libs(builddir, verbose)
    # TODO: these flags should probably be emitted also by `julia-config.jl` and `compiler_flags.jl`
    shlibdir = Sys.iswindows() ? Sys.BINDIR : joinpath(Sys.BINDIR, Base.LIBDIR)
    private_shlibdir = joinpath(Sys.BINDIR, Base.PRIVATE_LIBDIR)
    libfiles = String[]
    dlext = "." * Libdl.dlext
    for dir in (shlibdir, private_shlibdir)
        if Sys.iswindows() || Sys.isapple()
            append!(libfiles, joinpath.(dir, filter(x -> endswith(x, dlext) && !startswith(x, "sys"), readdir(dir))))
        else
            append!(libfiles, joinpath.(dir, filter(x -> occursin(r"^lib.+\.so(?:\.\d+)*$", x), readdir(dir))))
        end
    end
    filter!(v -> !occursin(r"debug", v), libfiles)
    copy_files_array(libfiles, builddir, verbose, "Copy Julia libraries to build directory:")
end
