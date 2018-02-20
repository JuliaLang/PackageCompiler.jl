using ArgParse, PackageCompiler

Base.@ccallable function julia_main(args::Vector{String})::Cint

    s = ArgParseSettings("Static Julia Compiler",
                         version = "$(basename(@__FILE__)) version 0.7-DEV",
                         add_version = true)

    @add_arg_table s begin
        "juliaprog"
            arg_type = String
            required = true
            help = "Julia program to compile"
        "cprog"
            arg_type = String
            default = nothing
            help = "C program to compile (required only when building an executable; if not provided a minimal driver program is used)"
        "builddir"
            arg_type = String
            default = "builddir"
            help = "directory used for building, either absolute or relative to the Julia program directory"
        "--verbose", "-v"
            action = :store_true
            help = "increase verbosity"
        "--quiet", "-q"
            action = :store_true
            help = "suppress non-error messages"
        "--clean", "-c"
            action = :store_true
            help = "delete build directory"
        "--autodeps", "-a"
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
    end

    s.epilog = """
        examples:\n
        \ua0\ua0juliac.jl -vae hello.jl        # verbose, build executable and deps\n
        \ua0\ua0juliac.jl -vae hello.jl prog.c # embed into user defined C program\n
        \ua0\ua0juliac.jl -qo hello.jl         # quiet, build object file only\n
        \ua0\ua0juliac.jl -vosej hello.jl      # build all and sync Julia libs
        """

    parsed_args = parse_args(args, s)

    # TODO: in future it may be possible to broadcast dictionary indexing, see: https://discourse.julialang.org/t/accessing-multiple-values-of-a-dictionary/8648
    if !any(getindex.(parsed_args, ["clean", "object", "shared", "executable", "julialibs"]))
        parsed_args["quiet"] || println("nothing to do, exiting\ntry \"$(basename(@__FILE__)) -h\" for more information")
        exit(0)
    end

    juliaprog = pop!(parsed_args, "juliaprog")
    kw_args = map(parsed_args) do kv
        if PackageCompiler.julia_v07
            Symbol(replace(kv[1], "-" => "_")) => kv[2]
        else
            Symbol(replace(kv[1], "-", "_")) => kv[2]
        end
    end
    PackageCompiler.static_julia(juliaprog; kw_args...)

    return 0
end

if get(ENV, "COMPILE_STATIC", "false") == "false"
    julia_main(ARGS)
end
