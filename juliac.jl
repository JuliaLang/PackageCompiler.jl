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
            help = "C program to compile (if not provided, a minimal standard program is used)"
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
        "--cpu-target", "-C"
            arg_type = String
            default = nothing
            metavar = "<target>"
            help = "limit usage of CPU features up to <target>"
        "--optimize", "-O"
            arg_type = Int
            default = nothing
            range_tester = (x -> 0 <= x <= 3)
            metavar = "{0,1,2,3}"
            help = "set optimization level"
        "-g"
            arg_type = Int
            default = nothing
            range_tester = (x -> 0 <= x <= 2)
            dest_name = "debug"
            metavar = "{0,1,2}"
            help = "set debugging information level"
        "--inline"
            arg_type = String
            default = nothing
            range_tester = (x -> x == "yes" || x == "no")
            metavar = "{yes|no}"
            help = "control whether inlining is permitted"
        "--check-bounds"
            arg_type = String
            default = nothing
            range_tester = (x -> x == "yes" || x == "no")
            metavar = "{yes|no}"
            help = "emit bounds checks always or never"
        "--math-mode"
            arg_type = String
            default = nothing
            range_tester = (x -> x == "ieee" || x == "fast")
            metavar = "{ieee,fast}"
            help = "set floating point optimizations"
        "--depwarn"
            arg_type = String
            default = nothing
            range_tester = (x -> x == "yes" || x == "no" || x == "error")
            metavar = "{yes|no|error}"
            help = "set syntax and method deprecation warnings"
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
        \ua0\ua0juliac.jl -ve hello.jl           # verbose, build executable\n
        \ua0\ua0juliac.jl -ve hello.jl myprog.c  # embed into user defined C program\n
        \ua0\ua0juliac.jl -qo hello.jl           # quiet, build object file\n
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
        parsed_args["cpu-target"],
        parsed_args["optimize"],
        parsed_args["debug"],
        parsed_args["inline"],
        parsed_args["check-bounds"],
        parsed_args["math-mode"],
        parsed_args["depwarn"],
        parsed_args["object"],
        parsed_args["shared"],
        parsed_args["executable"],
        parsed_args["julialibs"]
    )
end

function julia_compile(julia_program, c_program=nothing, build_dir="builddir", verbose=false, quiet=false, clean=false,
                       cpu_target=nothing, optimize=nothing, debug=nothing, inline=nothing, check_bounds=nothing, math_mode=nothing, depwarn=nothing,
                       object=false, shared=false, executable=true, julialibs=true)

    verbose && quiet && (verbose = false)

    julia_program = abspath(julia_program)
    isfile(julia_program) || error("Cannot find file:\n  \"$julia_program\"")
    quiet || println("Julia program file:\n  \"$julia_program\"")

    c_program = c_program == nothing ? joinpath(@__DIR__, "program.c") : abspath(c_program)
    isfile(c_program) || error("Cannot find file:\n  \"$c_program\"")
    quiet || println("C program file:\n  \"$c_program\"")

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

    file_name = splitext(basename(julia_program))[1]
    o_file = file_name * ".o"
    s_file = "lib" * file_name * ".$(Libdl.dlext)"
    e_file = file_name * (is_windows() ? ".exe" : "")

    # TODO: these should probably be emitted from julia-config also:
    shlibdir = is_windows() ? JULIA_HOME : abspath(JULIA_HOME, Base.LIBDIR)
    private_shlibdir = abspath(JULIA_HOME, Base.PRIVATE_LIBDIR)

    delete_object = false
    if object || shared || executable
        julia_cmd = `$(Base.julia_cmd()) --startup-file=no`
        cpu_target == nothing || splice!(julia_cmd.exec, 2, ["-C$cpu_target"])
        optimize == nothing || push!(julia_cmd.exec, "-O$optimize")
        debug == nothing || push!(julia_cmd.exec, "-g$debug")
        inline == nothing || push!(julia_cmd.exec, "--inline=$inline")
        check_bounds == nothing || push!(julia_cmd.exec, "--check-bounds=$check_bounds")
        math_mode == nothing || push!(julia_cmd.exec, "--math-mode=$math_mode")
        depwarn == nothing || splice!(julia_cmd.exec, 5, ["--depwarn=$depwarn"])
        is_windows() && (julia_program = replace(julia_program, "\\", "\\\\"))
        expr = "
  VERSION >= v\"0.7+\" && Base.init_load_path($(repr(JULIA_HOME))) # initialize location of site-packages
  empty!(Base.LOAD_CACHE_PATH) # reset / remove any builtin paths
  push!(Base.LOAD_CACHE_PATH, abspath(\"cache_ji_v$VERSION\")) # enable usage of precompiled files
  include($(repr(julia_program))) # include \"julia_program\" file
  empty!(Base.LOAD_CACHE_PATH) # reset / remove build-system-relative paths"
        command = `$julia_cmd -e $expr`
        verbose && println("Populate \".ji\" local cache:\n  $command")
        run(command)
        command = `$julia_cmd --output-o $o_file -e $expr`
        verbose && println("Build object file \"$o_file\":\n  $command")
        run(command)
        object || (delete_object = true)
    end

    if shared || executable
        command = `$(Base.julia_cmd()) --startup-file=no $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl"))`
        cflags = Base.shell_split(readstring(`$command --cflags`))
        ldflags = Base.shell_split(readstring(`$command --ldflags`))
        ldlibs = Base.shell_split(readstring(`$command --ldlibs`))
        cc = is_windows() ? "x86_64-w64-mingw32-gcc" : "gcc"
    end

    if shared || executable
        command = `$cc -m64 -shared -o $s_file $o_file $cflags $ldflags $ldlibs`
        if is_apple()
            command = `$command -Wl,-install_name,@rpath/lib$file_name.dylib`
        elseif is_windows()
            command = `$command -Wl,--export-all-symbols`
        end
        verbose && println("Build shared library \"$s_file\":\n  $command")
        run(command)
    end

    if executable
        command = `$cc -m64 -o $e_file $c_program $s_file $cflags $ldflags $ldlibs`
        if is_apple()
            command = `$command -Wl,-rpath,@executable_path`
        elseif is_unix()
            command = `$command -Wl,-rpath,\$ORIGIN`
        end
        verbose && println("Build executable file \"$e_file\":\n  $command")
        run(command)
    end

    if delete_object && isfile(o_file)
        verbose && println("Delete object file \"$o_file\"")
        rm(o_file)
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
