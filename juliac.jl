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
            help = "C program to compile (required only when building an executable; if not provided a minimal driver program is used)"
        "--verbose", "-v"
            action = :store_true
            help = "increase verbosity"
        "--quiet", "-q"
            action = :store_true
            help = "suppress non-error messages"
        "--builddir", "-d"
            arg_type = String
            metavar = "<dir>"
            help = "build directory"
        "--outname", "-n"
            arg_type = String
            metavar = "<name>"
            help = "output files basename"
        "--clean", "-c"
            action = :store_true
            help = "remove build directory"
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
        "--rmtemp", "-r"
            action = :store_true
            help = "remove temporary build files"
        "--julialibs", "-j"
            action = :store_true
            help = "copy Julia libraries to build directory"
        "--sysimage", "-J"
            arg_type = String
            metavar = "<file>"
            help = "start up with the given system image file"
        "--precompiled"
            arg_type = String
            metavar = "{yes|no}"
            range_tester = (x -> x ∈ ("yes", "no"))
            help = "use precompiled code from system image if available"
        "--compilecache"
            arg_type = String
            metavar = "{yes|no}"
            range_tester = (x -> x ∈ ("yes", "no"))
            help = "enable/disable incremental precompilation of modules"
        "--home", "-H"
            arg_type = String
            metavar = "<dir>"
            help = "set location of `julia` executable"
        "--startup-file"
            arg_type = String
            metavar = "{yes|no}"
            range_tester = (x -> x ∈ ("yes", "no"))
            help = "load ~/.juliarc.jl"
        "--handle-signals"
            arg_type = String
            metavar = "{yes|no}"
            range_tester = (x -> x ∈ ("yes", "no"))
            help = "enable or disable Julia's default signal handlers"
        "--compile"
            arg_type = String
            metavar = "{yes|no|all|min}"
            range_tester = (x -> x ∈ ("yes", "no", "all", "min"))
            help = "enable or disable JIT compiler, or request exhaustive compilation"
        "--cpu-target", "-C"
            arg_type = String
            metavar = "<target>"
            help = "limit usage of CPU features up to <target> (implies default `--precompiled=no`)"
        "--optimize", "-O"
            arg_type = Int
            metavar = "{0,1,2,3}"
            range_tester = (x -> x ∈ (0, 1, 2, 3))
            help = "set the optimization level"
        "-g"
            arg_type = Int
            dest_name = "debug"
            metavar = "<level>"
            range_tester = (x -> x ∈ (0, 1, 2))
            help = "enable / set the level of debug info generation"
        "--inline"
            arg_type = String
            metavar = "{yes|no}"
            range_tester = (x -> x ∈ ("yes", "no"))
            help = "control whether inlining is permitted"
        "--check-bounds"
            arg_type = String
            metavar = "{yes|no}"
            range_tester = (x -> x ∈ ("yes", "no"))
            help = "emit bounds checks always or never"
        "--math-mode"
            arg_type = String
            metavar = "{ieee,fast}"
            range_tester = (x -> x ∈ ("ieee", "fast"))
            help = "disallow or enable unsafe floating point optimizations"
        "--depwarn"
            arg_type = String
            metavar = "{yes|no|error}"
            range_tester = (x -> x ∈ ("yes", "no", "error"))
            help = "enable or disable syntax and method deprecation warnings"
        "--cc"
            arg_type = String
            metavar = "<cc>"
            help = "system C compiler"
        "--cc-flags"
            arg_type = String
            metavar = "<flags>"
            help = "pass custom flags to the system C compiler when building a shared library or executable"
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
    if !any(getindex.(Ref(parsed_args), ["clean", "object", "shared", "executable", "rmtemp", "julialibs"]))
        parsed_args["quiet"] || println("nothing to do, exiting\ntry \"$(basename(@__FILE__)) -h\" for more information")
        exit(0)
    end

    juliaprog = pop!(parsed_args, "juliaprog")
    if PackageCompiler.julia_v07
        filter!(kv -> kv.second ∉ (nothing, false), parsed_args)
    else
        filter!((k, v) -> v ∉ (nothing, false), parsed_args)
    end
    if PackageCompiler.julia_v07
        kw_args = [Symbol(replace(kv.first, "-" => "_")) => kv.second for kv in parsed_args]
    else
        kw_args = map(parsed_args) do kv
            Symbol(replace(kv.first, "-", "_")) => kv.second
        end
    end

    static_julia(juliaprog; kw_args...)

    return 0
end

if get(ENV, "COMPILE_STATIC", "false") == "false"
    julia_main(ARGS)
end
