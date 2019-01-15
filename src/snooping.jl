using Pkg, Serialization


function snoop(package, snoopfile, outputfile, reuse = false)
    packages = extract_using(snoopfile)
    command = """
    using Pkg, PackageCompiler, $package
    include($(repr(snoopfile)))
    """
    # let's use a file in the PackageCompiler dir,
    # so it doesn't get lost if a later step fails
    tmp_file = sysimg_folder("precompile_tmp.jl")
    if !reuse
        julia = Base.julia_cmd()[1]
        run(`$julia --compile=all -O0 --trace-compile=$tmp_file -e $command`)
    end
    M = Module()
    @eval M begin
        using Pkg
        using $(Symbol(package))
    end
    actually_used = extract_used_packages(tmp_file)
    require_uninstalled.(actually_used, (M,))
    line_idx = 0
    missed = 0
    open(outputfile, "w") do io
        println(io, """
        PackageCompiler.require_uninstalled.($(repr(actually_used)), @__MODULE__)
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
        file2snoop = normpath(abspath(joinpath(abs_package_path, snoopfile)))
        package = package_folder(get_root_dir(abs_package_path))
        isdir(package) || mkpath(package)
        precompile_file = joinpath(package, "precompile.jl")
        snoop(module_name, file2snoop, precompile_file; additional_packages = additional_packages)
        return precompile_file
    end
    # merge all of the temporary files into a single output
    open(userimg, "w") do output
        # Prevent this from being put into the Main namespace
        println(output, "module CompilationModule")
        for (pkg, _) in packages
            println(output, "import $pkg")
        end
        for path in snooped_precompiles
            open(input -> write(output, input), path)
            println(output)
        end
        println(output, "end # let")
    end
    nothing
end
