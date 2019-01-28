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
    tmp_file = sysimg_folder("precompile_tmp.jl")
    if !reuse
        run_julia(command, compile = "all", O = 0, g = 1, trace_compile = tmp_file)
    end
    actually_used = extract_used_packages(tmp_file)
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
