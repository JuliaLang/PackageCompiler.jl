using Pkg, Serialization


function snoop(snoopfile::String, output_io::IO)
    command = """
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
    run_julia(command, compile = "all", O = 0, g = 1, trace_compile = tmp_file)
    line_idx = 0; missed = 0
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
                println(output_io, "try;", line, "; catch e; @debug \"couldn't precompile statement $line_idx\" exception = e; end")
            else
                missed += 1
                @debug "Incomplete line in precompile file: $line"
            end
        catch e
            missed += 1
            @debug "Parse error in precompile file: $line" exception=e
        end
    end
    @info "used $(line_idx - missed) out of $line_idx precompile statements"
end

function snoop_packages(
        packages::Vector{String}, file::String;
        blacklist::Vector{Symbol} = Symbol[],
        blacklist_init::Vector{Symbol} = Symbol[],
        install_dependencies::Bool = false
    )
    pkgs = PackageSpec.(packages)
    ctx = Types.Context()
    resolve_packages!(ctx, pkgs)
    snoopfiles = get_snoopfile.(pkgs)
    packages = resolve_full_dependencies(pkgs, ctx)
    uninstalled = not_installed(packages)
    if !isempty(uninstalled)
        if install_dependencies
            Pkg.add(uninstalled)
        else
            error("""Not all dependencies of this project are installed.
            Please add them manually or set `install_dependencies = true`.
            If you want to install them manually, please execute:
                using Pkg
                pkg"add $(join(getfield.(uninstalled, :name), " "))"
            """)
        end
    end
    # remove blacklisted packages from full list of packages
    package_names = setdiff(getfield.(packages, :name), string.(blacklist))

    inits = setdiff(package_names, string.(blacklist_init))
    usings = join(package_names, ", ")
    inits = join(inits, ", ")
    open(file, "w") do io
        println(io, """
        import $usings
        for Mod in [$inits]
            isdefined(Mod, :__init__) && Mod.__init__()
        end
        """)
        for file in snoopfiles
            snoop(file, io)
        end
    end
end
