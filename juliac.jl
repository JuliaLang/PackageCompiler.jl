## Assumptions:
## 1. gcc / x86_64-w64-mingw32-gcc is available and is in path
## 2. Package ArgParse is installed

using ArgParse

function main(args)

    s = ArgParseSettings("Julia AOT compiler" *
                         "\n\nhelper script to build libraries and executables from Julia code",
                         version = "$(basename(@__FILE__)) version 0.6",
                         add_version = true)

    @add_arg_table s begin
        "juliaprog"
            arg_type = String
            required = true
            help = "Julia program to compile"
        "cprog"
            arg_type = String
            default = nothing
            help = "C program to compile (required only when building an executable; if not provided a minimal standard program is used)"
        "builddir"
            arg_type = String
            default = "builddir"
            help = "build directory, either absolute or relative to the Julia program directory"
        "--verbose", "-v"
            action = :store_true
            help = "increase verbosity"
        "--quiet", "-q"
            action = :store_true
            help = "suppress non-error messages"
        "--clean", "-c"
            action = :store_true
            help = "delete builddir"
        "--sysimage", "-J"
            arg_type = String
            default = nothing
            metavar = "<file>"
            help = "start up with the given system image file"
        "--compile"
            arg_type = String
            default = nothing
            metavar = "{yes|no|all|min}"
            range_tester = (x -> x == "yes" || x == "no" || x == "all" || x == "min")
            help = "enable or disable JIT compiler, or request exhaustive compilation"
        "--cpu-target", "-C"
            arg_type = String
            default = nothing
            metavar = "<target>"
            help = "limit usage of CPU features up to <target>"
        "--optimize", "-O"
            arg_type = Int
            default = nothing
            metavar = "{0,1,2,3}"
            range_tester = (x -> 0 <= x <= 3)
            help = "set optimization level"
        "-g"
            arg_type = Int
            default = nothing
            dest_name = "debug"
            metavar = "{0,1,2}"
            range_tester = (x -> 0 <= x <= 2)
            help = "set debugging information level"
        "--inline"
            arg_type = String
            default = nothing
            metavar = "{yes|no}"
            range_tester = (x -> x == "yes" || x == "no")
            help = "control whether inlining is permitted"
        "--check-bounds"
            arg_type = String
            default = nothing
            metavar = "{yes|no}"
            range_tester = (x -> x == "yes" || x == "no")
            help = "emit bounds checks always or never"
        "--math-mode"
            arg_type = String
            default = nothing
            metavar = "{ieee,fast}"
            range_tester = (x -> x == "ieee" || x == "fast")
            help = "set floating point optimizations"
        "--depwarn"
            arg_type = String
            default = nothing
            metavar = "{yes|no|error}"
            range_tester = (x -> x == "yes" || x == "no" || x == "error")
            help = "set syntax and method deprecation warnings"
        "--auto", "-a"
            action = :store_true
            help = "automatically build required dependencies"
        "--object", "-o"
            action = :store_true
            help = "build object file"
        "--shared", "-s"
            action = :store_true
            help = "build shared library"
        "--executable", "-e"
            action = :store_true
            help = "build executable file"
        "--julialibs", "-j"
            action = :store_true
            help = "sync Julia libraries to builddir"
    end

    s.epilog = """
        examples:\n
        \ua0\ua0juliac.jl -vae hello.jl          # verbose, auto, build executable\n
        \ua0\ua0juliac.jl -vae hello.jl myprog.c # embed into user defined C program\n
        \ua0\ua0juliac.jl -qo hello.jl           # quiet, build object file only\n
        \ua0\ua0juliac.jl -vosej hello.jl        # build all and sync Julia libs\n
        """

    parsed_args = parse_args(args, s)

    if !any([parsed_args["clean"], parsed_args["object"], parsed_args["shared"], parsed_args["executable"], parsed_args["julialibs"]])
        parsed_args["quiet"] || println("Nothing to do, exiting\nTry \"$(basename(@__FILE__)) -h\" for more information")
        exit(0)
    end

    julia_compile(
        parsed_args["juliaprog"],
        parsed_args["cprog"],
        parsed_args["builddir"],
        parsed_args["verbose"],
        parsed_args["quiet"],
        parsed_args["clean"],
        parsed_args["sysimage"],
        parsed_args["compile"],
        parsed_args["cpu-target"],
        parsed_args["optimize"],
        parsed_args["debug"],
        parsed_args["inline"],
        parsed_args["check-bounds"],
        parsed_args["math-mode"],
        parsed_args["depwarn"],
        parsed_args["auto"],
        parsed_args["object"],
        parsed_args["shared"],
        parsed_args["executable"],
        parsed_args["julialibs"]
    )
end

function julia_compile(julia_program, c_program=nothing, build_dir="builddir", verbose=false, quiet=false,
                       clean=false, sysimage = nothing, compile=nothing, cpu_target=nothing, optimize=nothing,
                       debug=nothing, inline=nothing, check_bounds=nothing, math_mode=nothing, depwarn=nothing,
                       auto=false, object=false, shared=false, executable=true, julialibs=true)

    verbose && quiet && (verbose = false)

    if auto
        executable && (shared = true)
        shared && (object = true)
    end

    julia_program = abspath(julia_program)
    isfile(julia_program) || error("Cannot find file:\n  \"$julia_program\"")
    quiet || println("Julia program file:\n  \"$julia_program\"")

    if executable
        c_program = c_program == nothing ? joinpath(@__DIR__, "program.c") : abspath(c_program)
        isfile(c_program) || error("Cannot find file:\n  \"$c_program\"")
        quiet || println("C program file:\n  \"$c_program\"")
    end

    cd(dirname(julia_program))

    build_dir = abspath(build_dir)
    quiet || println("Build directory:\n  \"$build_dir\"")

    if clean
        if isdir(build_dir)
            verbose && println("Delete build directory")
            rm(build_dir, recursive=true)
        else
            verbose && println("Build directory does not exist, nothing to delete")
        end
    end

    if !isdir(build_dir)
        verbose && println("Make build directory")
        mkpath(build_dir)
    end

    if pwd() != build_dir
        verbose && println("Change to build directory")
        cd(build_dir)
    else
        verbose && println("Already in build directory")
    end

    julia_program_basename = splitext(basename(julia_program))[1]
    o_file = julia_program_basename * ".o"
    s_file = "lib" * julia_program_basename * ".$(Libdl.dlext)"
    e_file = julia_program_basename * (is_windows() ? ".exe" : "")
    tmp_dir = "tmp_v$VERSION"

    # TODO: these should probably be emitted from julia-config also:
    shlibdir = is_windows() ? JULIA_HOME : abspath(JULIA_HOME, Base.LIBDIR)
    private_shlibdir = abspath(JULIA_HOME, Base.PRIVATE_LIBDIR)

    if object
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
        is_windows() && (julia_program = replace(julia_program, "\\", "\\\\"))
        expr = "
  VERSION >= v\"0.7+\" && Base.init_load_path($(repr(JULIA_HOME))) # initialize location of site-packages
  empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
  push!(Base.LOAD_CACHE_PATH, abspath(\"$tmp_dir\")) # enable usage of precompiled files
  include($(repr(julia_program))) # include \"julia_program\" file
  empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
        command = `$julia_cmd -e $expr`
        verbose && println("Build \".ji\" files:\n  $command")
        run(command)
        command = `$julia_cmd --output-o $(joinpath(tmp_dir, o_file)) -e $expr`
        verbose && println("Build object file \"$o_file\":\n  $command")
        run(command)
    end

    if shared || executable
        command = `$(Base.julia_cmd()) --startup-file=no $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl"))`
        cflags = Base.shell_split(readstring(`$command --cflags`))
        ldflags = Base.shell_split(readstring(`$command --ldflags`))
        ldlibs = Base.shell_split(readstring(`$command --ldlibs`))
        cc = is_windows() ? "x86_64-w64-mingw32-gcc" : "gcc"
    end

    if shared
        command = `$cc -m64 -shared -o $s_file $(joinpath(tmp_dir, o_file)) $cflags $ldflags $ldlibs`
        if is_apple()
            command = `$command -Wl,-install_name,@rpath/lib$julia_program_basename.dylib`
        elseif is_windows()
            command = `$command -Wl,--export-all-symbols`
        end
        verbose && println("Build shared library \"$s_file\":\n  $command")
        run(command)
    end

    if executable
        push!(cflags, "-DJULIAC_PROGRAM_LIBNAME=\"lib$julia_program_basename\"")
        command = `$cc -m64 -o $e_file $c_program $s_file $cflags $ldflags $ldlibs`
        if is_apple()
            command = `$command -Wl,-rpath,@executable_path`
        elseif is_unix()
            command = `$command -Wl,-rpath,\$ORIGIN`
        end
        verbose && println("Build executable file \"$e_file\":\n  $command")
        run(command)
    end

    if julialibs
        verbose && println("Sync Julia libraries:")
        libfiles = String[]
        dlext = "." * Libdl.dlext
        for dir in (shlibdir, private_shlibdir)
            if is_windows() || is_apple()
                append!(libfiles, joinpath.(dir, filter(x -> endswith(x, dlext), readdir(dir))))
            else
                append!(libfiles, joinpath.(dir, filter(x -> ismatch(r"^lib.+\.so(?:\.\d+)*$", x), readdir(dir))))
            end
        end
        sync = false
        for src in libfiles
            ismatch(r"debug", src) && continue
            dst = basename(src)
            if filesize(src) != filesize(dst) || ctime(src) > ctime(dst) || mtime(src) > mtime(dst)
                verbose && println("  $dst")
                cp(src, dst, remove_destination=true, follow_symlinks=false)
                sync = true
            end
        end
        sync || verbose && println("  none")
    end
end

main(ARGS)
