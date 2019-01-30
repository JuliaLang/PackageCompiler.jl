using Pkg, Serialization


function snoop(tomlpath, snoopfile, outputfile, reuse = false)
    packages = extract_using(snoopfile)
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
    actually_used = extract_used_packages(tmp_file)
    if tomlpath != nothing
        # add toml packages, in case extract_used_packages misses a package
        deps = get(TOML.parsefile(tomlpath), "deps", Dict{String, Any}())
        union!(actually_used, string.(keys(deps)))
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
        using PackageCompiler
        PackageCompiler.require_uninstalled.($(repr(actually_used)), (@__MODULE__,))
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
                    println(io, "try;", line, "; catch e; @warn \"couldn't precompile statement $line_idx\" exception = e; end")
                else
                    missed += 1
                    @warn "Incomplete line in precompile file: $line"
                end
            catch e
                missed += 1
                @warn "Parse error in precompile file: $line" exception=e
            end
        end
    end
    @info "used $(line_idx - missed) out of $line_idx precompile statements"
    outputfile
end


"""
    snoop_userimg(userimg, packages::Tuple{String, String}...)

    Traces all function calls in packages and writes out `precompile` statements into the file `userimg`
"""
function snoop_userimg(userimg, packages::Tuple{String, String}...; additional_packages = Symbol[])
    snooped_precompiles = map(packages) do package_snoopfile
        package, snoopfile = package_snoopfile
        module_name = Symbol(package)
        toml, runtests = package_toml(module_name)
        pkg_root = normpath(joinpath(dirname(runtests), ".."))
        file2snoop = if isfile(pkg_root, snoopfile)
            joinpath(pkg_root, snoopfile)
        else
            joinpath(pkg_root, snoopfile)
        end
        precompile_file = package_folder(package, "precompile.jl")
        snoop(toml, file2snoop, precompile_file)
        return precompile_file
    end
    # merge all of the temporary files into a single output
    open(userimg, "w") do output
        for path in snooped_precompiles
            open(input -> write(output, input), path)
        end
    end
    nothing
end
