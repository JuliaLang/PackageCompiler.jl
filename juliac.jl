## Assumptions:
## 1. gcc / x86_64-w64-mingw32-gcc is available and is in path
## 2. Package ArgParse is installed

using ArgParse

function main(args)

    s = ArgParseSettings("Static AOT Julia compilation.")

    @add_arg_table s begin
        "juliaprog"
            help = "julia program to compile"
            arg_type = String
            required = true
        "cprog"
            help = "c program to compile (if not provided, a minimal standard program is used)"
            arg_type = String
            default = nothing
        "builddir"
            help = "build directory, either absolute or relative to the julia program directory"
            arg_type = String
            default = "builddir"
        "--verbose", "-v"
            help = "increase verbosity"
            action = :store_true
        "--quiet", "-q"
            help = "suppress non-error messages"
            action = :store_true
        "--object", "-o"
            help = "build object file"
            action = :store_true
        "--shared", "-s"
            help = "build shared library"
            action = :store_true
        "--executable", "-e"
            help = "build executable file"
            action = :store_true
        "--julialibs", "-j"
            help = "sync julia libraries to builddir"
            action = :store_true
        "--clean", "-c"
            help = "delete builddir"
            action = :store_true
    end

    parsed_args = parse_args(args, s)

    if !any([parsed_args["object"], parsed_args["shared"], parsed_args["executable"], parsed_args["julialibs"], parsed_args["clean"]])
        if !parsed_args["quiet"]
            println("Nothing to do, exiting\nTry \"$(basename(@__FILE__)) -h\" for more information")
        end
        exit(0)
    end

    julia_compile(
        parsed_args["juliaprog"],
        parsed_args["cprog"],
        parsed_args["builddir"],
        parsed_args["verbose"],
        parsed_args["quiet"],
        parsed_args["object"],
        parsed_args["shared"],
        parsed_args["executable"],
        parsed_args["julialibs"],
        parsed_args["clean"]
    )
end

function julia_compile(julia_program, c_program=nothing, build_dir="builddir", verbose=false, quiet=false,
                       object=false, shared=false, executable=true, julialibs=true, clean=false)

    if verbose && quiet
        verbose = false
    end

    julia_program = abspath(julia_program)
    if !isfile(julia_program)
        error("Cannot find file:\n\"$julia_program\"")
    end
    if !quiet
        println("Julia program file:\n\"$julia_program\"")
    end

    if c_program == nothing
        c_program = joinpath(@__DIR__, "program.c")
    else
        c_program = abspath(c_program)
    end
    if !isfile(c_program)
        error("Cannot find file:\n\"$c_program\"")
    end
    if !quiet
        println("C program file:\n\"$c_program\"")
    end

    cd(dirname(julia_program))

    build_dir = abspath(build_dir)
    if !quiet
        println("Build directory:\n\"$build_dir\"")
    end

    if clean
        if !isdir(build_dir)
            if verbose
                println("Build directory does not exist")
            end
        else
            if verbose
                println("Delete build directory")
            end
            rm(build_dir, recursive=true)
        end
        return
    end

    if !isdir(build_dir)
        if verbose
            println("Make build directory")
        end
        mkpath(build_dir)
    end
    if pwd() != build_dir
        if verbose
            println("Change to build directory")
        end
        cd(build_dir)
    else
        if verbose
            println("Already in build directory")
        end
    end

    file_name = splitext(basename(julia_program))[1]
    o_file = file_name * ".o"
    s_file = "lib" * file_name * ".$(Libdl.dlext)"
    e_file = file_name * (is_windows() ? ".exe" : "")

    # TODO: these should probably be emitted from julia-config also:
    julia_pkglibdir = joinpath(dirname(Pkg.dir()), "lib", basename(Pkg.dir()))
    shlibdir = is_windows() ? JULIA_HOME : abspath(JULIA_HOME, Base.LIBDIR)
    private_shlibdir = abspath(JULIA_HOME, Base.PRIVATE_LIBDIR)

    if is_windows()
        julia_program = replace(julia_program, "\\", "\\\\")
        julia_pkglibdir = replace(julia_pkglibdir, "\\", "\\\\")
    end

    delete_object = false
    if object || shared || executable
        command = `"$(Base.julia_cmd())" "--startup-file=no" "--output-o" "$o_file" "-e"
                   "include(\"$julia_program\"); push!(Base.LOAD_CACHE_PATH, \"$julia_pkglibdir\"); empty!(Base.LOAD_CACHE_PATH)"`
        if verbose
            println("Build object file \"$o_file\":\n$command")
        end
        run(command)
        if !object
            delete_object = true
        end
    end

    if shared || executable
        command = `$(Base.julia_cmd()) $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl"))`
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
        if verbose
            println("Build shared library \"$s_file\":\n$command")
        end
        run(command)
    end

    if executable
        command = `$cc -m64 -o $e_file $c_program $s_file $cflags $ldflags $ldlibs`
        if is_apple()
            command = `$command -Wl,-rpath,@executable_path`
        elseif is_unix()
            command = `$command -Wl,-rpath,\$ORIGIN`
        end
        if verbose
            println("Build executable file \"$e_file\":\n$command")
        end
        run(command)
    end

    if delete_object && isfile(o_file)
        if verbose
            println("Delete object file \"$o_file\"")
        end
        rm(o_file)
    end

    if julialibs
        if verbose
            println("Sync Julia libraries:")
        end
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
            if ismatch(r"debug", src)
                continue
            end
            dst = basename(src)
            if filesize(src) != filesize(dst) || ctime(src) > ctime(dst) || mtime(src) > mtime(dst)
                if verbose
                    println(" $dst")
                end
                cp(src, dst, remove_destination=true, follow_symlinks=false)
                sync = true
            end
        end
        if verbose && !sync
            println(" none")
        end
    end
end

main(ARGS)
