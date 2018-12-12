using Pkg, Serialization

# Taken from SnoopCompile, modifying just `julia_cmd`
function snoop_vanilla(flags, filename, commands, pwd)
    println("Launching new julia process to run commands...")
    # addprocs will run the unmodified version of julia, so we
    # launch it as a command.
    code_object = """
    using Serialization
    while !eof(stdin)
        code = deserialize(stdin)
        @show code
        Core.eval(Main, code)
    end
    """

    code = `$julia_cmd $flags -O0 --compile=all --startup-file=no --compile=all --eval $code_object`
    process = open(Cmd(code, dir=pwd), stdout, write=true)
    serialize(process, quote
        let io = open($filename, "w")
            ccall(:jl_dump_compiles, Nothing, (Ptr{Nothing},), io.handle)
            try
                $commands
            finally
                ccall(:jl_dump_compiles, Nothing, (Ptr{Nothing},), C_NULL)
                close(io)
            end
        end
        exit()
    end)
    wait(process)
    println("done.")
    nothing
end


using Pkg
function get_dependencies(package_root)
    project = joinpath(package_root, "Project.toml")
    if !isfile(project)
        error("Your package needs to have a Project.toml for static compilation. Please read here how to upgrade:")
    end
    project_deps = Pkg.TOML.parsefile(project)["deps"]
    Symbol.(keys(project_deps))
end


function snoop(package, snoopfile, outputfile)
    command = """
    using Pkg, $package
    package_path = abspath(joinpath(dirname(pathof($package)), ".."))
    Pkg.activate(package_path)
    Pkg.instantiate()
    include($(repr(snoopfile)))
    """
    tmp_file = joinpath(@__DIR__, "precompile_tmp.jl")
    julia_cmd = build_julia_cmd(
        get_backup!(false, nothing), nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, "all", nothing, "0", nothing, nothing, nothing, nothing
    )
    run(`$julia_cmd --trace-compile=$tmp_file -e $command`)
    M = Module()
    @eval M begin
        using Pkg
        using $package
        package_path = abspath(joinpath(dirname(pathof($package)), ".."))
        Pkg.activate(package_path)
        Pkg.instantiate()
    end
    deps = get_dependencies(M.package_path)
    deps_usings = string("using ", join(deps, ", "))
    @eval M begin
        $(Meta.parse(deps_usings))
    end
    open(outputfile, "w") do io
        println(io, """
        # if !isdefined(Base, :uv_eventloop)
        #     Base.reinit_stdio()
        # end
        Base.init_load_path()
        Base.init_depot_path()
        using Pkg
        Pkg.activate($(repr(M.package_path)))
        # Pkg.instantiate()
        using $package
        $deps_usings
        """)
        for line in eachline(tmp_file)
            # replace function instances, which turn up as typeof(func)().
            # TODO why would they be represented in a way that doesn't actually work?
            line = replace(line, r"typeof\(([\u00A0-\uFFFF\w_!´\.]*@?[\u00A0-\uFFFF\w_!´]+)\)\(\)" => s"\1")
            expr = Meta.parse(line, raise = false)
            if expr.head != :error
                try
                    M.eval(M, expr)
                    println(io, line)
                catch e
                    @warn "could not eval $line" exception = e
                end
            end
        end
    end
    rm(tmp_file, force = true)
    outputfile
end


"""
    snoop_userimg(userimg, packages::Tuple{String, String}...)

    Traces all function calls in packages and writes out `precompile` statements into the file `userimg`
"""
function snoop_userimg(userimg, packages::Tuple{String, String}...)
    snooped_precompiles = map(packages) do package_snoopfile
        package, snoopfile = package_snoopfile
        module_file = ""
        abs_package_path = if ispath(package)
            path = normpath(abspath(package))
            module_file = joinpath(path, "src", basename(path) * ".jl")
            path
        else
            module_file = Base.find_package(package)
            normpath(module_file, "..", "..")
        end
        module_name = Symbol(splitext(basename(module_file))[1])
        println(module_name)
        file2snoop = normpath(abspath(joinpath(abs_package_path, snoopfile)))
        package = package_folder(get_root_dir(abs_package_path))
        isdir(package) || mkpath(package)
        precompile_file = joinpath(package, "precompile.jl")
        snoop(module_name, file2snoop, precompile_file)
        return precompile_file
    end
    # merge all of the temporary files into a single output
    open(userimg, "w") do output
        println(output, """
        # Prevent this from being put into the Main namespace
        Core.eval(Module(), quote
        """)
        for (pkg, _) in packages
            println(output, "import $pkg")
        end
        println(output, """
        for m in Base.loaded_modules_array()
            Core.isdefined(@__MODULE__, nameof(m)) || Core.eval(@__MODULE__, Expr(:(=), nameof(m), m))
        end
        """)
        for path in snooped_precompiles
            open(input -> write(output, input), path)
            println(output)
        end
        println(output, "end) # eval")
    end
    nothing
end
