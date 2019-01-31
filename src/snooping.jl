using Pkg, Serialization


function snoop(package, tomlpath, snoopfile, outputfile, reuse = false)

    command = """
    using Pkg, PackageCompiler
    """

    if tomlpath != nothing
        command *= """
        Pkg.activate($(repr(tomlpath)))
        Pkg.instantiate()
        """
    end

    command *= """
    # let's wrap the snoop file in a try catch...
    # This way we still do some snooping even if there is an error in the tests!
    try
        include($(repr(snoopfile)))
    catch e
        @warn("Snoop file errored. Precompile statements were recorded untill error!", exception = e)
    end
    """

    # let's use a file in the PackageCompiler dir,
    # so it doesn't get lost if later steps fail
    tmp_file = package_folder("precompile_tmp.jl")
    if !reuse
        run_julia(command, compile = "all", O = 0, g = 1, trace_compile = tmp_file)
    end
    used_packages = Set{String}() # e.g. from test/REQUIRE
    if package != nothing
        push!(used_packages, string(package))
    end
    usings = ""
    if tomlpath != nothing
        # add toml packages, in case extract_used_packages misses a package
        deps = get(TOML.parsefile(tomlpath), "deps", Dict{String, Any}())
        union!(used_packages, string.(keys(deps)))
    end
    if !isempty(used_packages)
        packages = join(used_packages, ", ")
        usings *= """
        using $packages
        for Mod in [$packages]
            isdefined(Mod, :__init__) && Mod.__init__()
        end
        """
    end

    line_idx = 0; missed = 0
    open(outputfile, "w") do io
        println(io, """
        # We need to use all used packages in the precompile file for maximum
        # usage of the precompile statements.
        # Since this can be any recursive dependency of the package we AOT compile,
        # we decided to just use them without installing them. An added
        # benefit is, that we can call __init__ this way more easily, since
        # incremental sysimage compilation won't call __init__ on `using`
        # https://github.com/JuliaLang/julia/issues/22910
        $usings
        # bring recursive dependencies of used packages and standard libraries into namespace
        for Mod in Base.loaded_modules_array()
            if !Core.isdefined(@__MODULE__, nameof(Mod))
                Core.eval(@__MODULE__, Expr(:const, Expr(:(=), nameof(Mod), Mod)))
            end
        end
        """)
        for line in eachline(tmp_file)
            line_idx += 1
            # replace function instances, which turn up as typeof(func)().
            # TODO why would they be represented in a way that doesn't actually work?
            line = replace(line, r"typeof\(([\u00A0-\uFFFF\w_!´\.]*@?[\u00A0-\uFFFF\w_!´]+)\)\(\)" => s"\1")
            # Is this ridicilous? Yes, it is! But we need a unique symbol to replace `_`,
            # which otherwise ends up as an uncatchable syntax error
            line = replace(line, r"\b_\b" => "🐃")
            try
                expr = Meta.parse(line, raise = true)
                if expr.head != :incomplete
                    # after all this, we still need to wrap into try catch,
                    # since some anonymous symbols won't be found...
                    println(io, "try;", line, "; catch e; @debug \"couldn't precompile statement $line_idx\" exception = e; end")
                else
                    missed += 1
                    @debug "Incomplete line in precompile file: $line"
                end
            catch e
                missed += 1
                @debug "Parse error in precompile file: $line" exception=e
            end
        end
    end
    @info "used $(line_idx - missed) out of $line_idx precompile statements"
    outputfile
end


function snoop_packages(packages::Symbol...; file = package_folder("incremental_precompile.jl"))
    finaltoml = Dict{Any, Any}(
        "deps" => Dict(),
        "compat" => Dict(),
    )
    toml_path = package_folder("Project.toml")
    open(file, "w") do compile_io
        println(compile_io, "# Precompile file for $(join(packages, " "))")
        # make sure we have all packages from toml installed
        println(compile_io, """
        using Pkg
        Pkg.activate($(repr(toml_path)))
        Pkg.instantiate()
        """)
        for package in packages
            precompiles = package_folder(string(package), "incremental_precompile.jl")
            toml, testfile = package_toml(package)
            snoop(package, toml, testfile, precompiles)
            pkg_toml = TOML.parsefile(toml)
            merge!(finaltoml["deps"], get(pkg_toml, "deps", Dict()))
            merge!(finaltoml["compat"], get(pkg_toml, "compat", Dict()))
            println(compile_io)
            write(compile_io, read(precompiles))
        end
    end
    finaltoml["name"] = "PackagesPrecompile"
    open(toml_path, "w") do io
        TOML.print(
            io, finaltoml,
            sorted = true, by = key-> (Types.project_key_order(key), key)
        )
    end
    return toml_path, file
end
