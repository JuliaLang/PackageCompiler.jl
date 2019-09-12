

function snoop(package, tomlpath, snoopfile, outputfile, reuse = false, blacklist = [])

    command = """
    using Pkg, PackageCompiler
    """

    if tomlpath !== nothing
        command *= """
        empty!(Base.LOAD_PATH)
        # Take LOAD_PATH from parent process
        append!(Base.LOAD_PATH, $(repr(Base.LOAD_PATH)))
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
        run_julia(command, compile = "all", O = 0, g = 1, trace_compile = tmp_file, startup_file = "no")
    end
    used_packages = Set{String}() # e.g. from test/REQUIRE
    if package !== nothing
        push!(used_packages, string(package))
    end
    usings = ""
    if tomlpath !== nothing
        # add toml packages, in case extract_used_packages misses a package
        deps = get(TOML.parsefile(tomlpath), "deps", Dict{String, Any}())
        union!(used_packages, string.(keys(deps)))
    end
    if !isempty(used_packages)
        packages = join(setdiff(used_packages,string.(blacklist)), ", ")
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


function snoop_packages(packages::Symbol...; blacklist = [], file = package_folder("incremental_precompile.jl"))
    finaltoml = Dict{Any, Any}(
        "deps" => Dict(),
        "compat" => Dict(),
    )
    toml_path = package_folder("Project.toml")
    manifest_dict = Dict{String, Vector{Dict{String, Any}}}()
    open(file, "w") do compile_io
        println(compile_io, "# Precompile file for $(join(packages, " "))")
        # make sure we have all packages from toml installed
        println(compile_io, """
        using Pkg
        empty!(Base.LOAD_PATH)
        # Take LOAD_PATH from parent process
        append!(Base.LOAD_PATH, $(repr(Base.LOAD_PATH)))
        Pkg.activate($(repr(toml_path)))
        Pkg.instantiate()
        """)
        for package in packages
            precompiles = package_folder(string(package), "incremental_precompile.jl")
            toml, snoopfile = package_toml(package)
            snoop(package, toml, snoopfile, precompiles, false, blacklist)
            pkg_toml = TOML.parsefile(toml)
            manifest = joinpath(dirname(toml), "Manifest.toml")
            if isfile(manifest) # not all get a manifest (only if pkg operations are executed I suppose)
                pkg_manifest = TOML.parsefile(manifest)
                for (name, pkgs) in pkg_manifest
                    pkg_vec = get!(()-> Dict{String, Any}[], manifest_dict, name)
                    append!(pkg_vec, pkgs); unique!(pkg_vec)
                end
            end
            merge!(finaltoml["deps"], get(pkg_toml, "deps", Dict()))
            merge!(finaltoml["compat"], get(pkg_toml, "compat", Dict()))
            println(compile_io)
            write(compile_io, read(precompiles))
        end
    end
    finaltoml["name"] = "PackagesPrecompile"
    write_toml(toml_path, finaltoml)
    manifest_path = package_folder("Manifest.toml")
    # make sure we don't reuse old manifests
    isfile(manifest_path) && rm(manifest_path)
    if !isempty(manifest_dict)
        write_toml(manifest_path, manifest_dict)
    end
    return toml_path, file
end
