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

function julia_compile(julia_program, build_dir="builddir", verbose=false, quiet=false,
                       object=false, shared=false, executable=true, julialibs=true, clean=false)

    if verbose && quiet
        verbose = false
    end

    julia_program = abspath(julia_program)
    if !isfile(julia_program)
        error("Cannot find file:\n\"$julia_program\"")
    end
    if !quiet
        println("Program file:\n\"$julia_program\"")
    end
    dir_name = dirname(julia_program)
    file_name = splitext(basename(julia_program))[1]

    cd(dir_name)
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

    o_file = file_name * ".o"
    s_file = "lib" * file_name * ".$(Libdl.dlext)"
    e_file = file_name * (is_windows() ? ".exe" : "")
    c_file = joinpath(@__DIR__, "program.c")

    julia_pkglibdir = joinpath(dirname(Pkg.dir()), "lib", basename(Pkg.dir()))

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
        if is_windows()
            command = `$command -Wl,--export-all-symbols`
        end
        if verbose
            println("Build shared library \"$s_file\":\n$command")
        end
        run(command)
    end

    if executable
        command = `$cc -m64 -o $e_file $c_file $s_file $cflags $ldflags $ldlibs`
        if is_unix()
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
        if is_windows()
            dir = JULIA_HOME
            libfiles = joinpath.(dir, filter(x -> ismatch(r".+\.dll$", x), readdir(dir)))
        else
            dir = joinpath(JULIA_HOME, "..", "lib")
            libfiles1 = joinpath.(dir, filter(x -> ismatch(r"^lib.*\.so(?:$|\.)", x), readdir(dir)))
            dir = joinpath(JULIA_HOME, "..", "lib", "julia")
            libfiles2 = joinpath.(dir, filter(x -> ismatch(r"^lib.*\.so(?:$|\.)", x), readdir(dir)))
            libfiles = vcat(libfiles1, libfiles2)
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
                cp(src, dst, remove_destination=true)
                sync = true
            end
        end
        if !sync
            println(" none")
        end
    end
end

main(ARGS)
