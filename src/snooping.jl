# Taken from SnoopCompile
function snoop_vanilla(filename, path)
    code_object = """
    while !eof(STDIN)
        eval(Main, deserialize(STDIN))
    end
    """
    julia_cmd = build_julia_cmd(
        get_backup!(false, nothing), nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing
    )
    @show julia_cmd
    in, io = open(`$julia_cmd --eval $code_object`, "w", STDOUT)
    serialize(in, quote
        import SnoopCompile
    end)
    # Now that the new process knows about SnoopCompile, it can
    # expand the macro in this next expression
    serialize(in, quote
          SnoopCompile.@snoop1 $filename include($(escape_string(path)))
    end)
    close(in)
    wait(io)
    println("done.")
    nothing
end

function snoop(path, compilationfile, csv)
    snoop_vanilla(abspath(csv), abspath(path))
    data = SnoopCompile.read(csv)
    pc = SnoopCompile.parcel(reverse!(data[2]))
    delims = r"([\{\} \n\(\),])_([\{\} \n\(\),])"
    tmp_mod = eval(:(module $(gensym()) end))
    open(compilationfile, "w") do io
        println(io, "Sys.__init__()")
        println(io, "Base.early_init()")
        for (k, v) in pc
            k == :unknown && continue
            try
                eval(tmp_mod, :(import $k))
                println(io, "import $k")
                info("import $k")
            catch e
                @warn "Module not found: $k"
            end
        end
        for (k, v) in pc
            for ln in v
                # replace `_` for free parameters, which print out a warning otherwise
                ln = replace(ln, delims, s"\1XXX\2")
                # only print out valid lines
                # TODO figure out the actual problems and why snoop compile emits invalid code
                try
                    parse(ln) # parse to make sure expression is parsing without error
                    # wrap in try catch to catch problematic code emitted by SnoopCompile
                    # without interupting the whole precompilation
                    # (usually, SnoopCompile emits 1% erroring statements)
                    println(io, "try\n    ", ln, "\nend")
                catch e
                    @warn "Not emitted because code couldn't parse: $ln"
                end
            end
        end
    end
end

function static_library_snoop()
    for (k, v) in pc
        for ln in v
            # replace `_` for free parameters, which print out a warning otherwise
            ln = replace(ln, delims, s"\1XXX\2")
            # only print out valid lines
            # TODO figure out the actual problems and why snoop compile emits invalid code
            try
                parse(ln) # parse to make sure expression is parsing without error
                # wrap in try catch to catch problematic code emitted by SnoopCompile
                # without interupting the whole precompilation
                # (usually, SnoopCompile emits 1% erroring statements)
                println(io, "try\n    ", ln, "\nend")
            catch e
                @warn "Not emitted because code couldn't parse: $ln"
            end
        end
    end
end


"""
    snoop_userimg(userimg, packages::Tuple{String, String}...)

    Traces all function calls in packages and writes out `precompile` statements into the file `userimg`
"""
function snoop_userimg(userimg, packages::Tuple{String, String}...)
    snooped_precompiles = map(packages) do package_snoopfile
        package, snoopfile = package_snoopfile
        abs_package_path = if ispath(package)
            normpath(abspath(package))
        else
            Pkg.dir(package)
        end
        file2snoop = normpath(abspath(joinpath(abs_package_path, snoopfile)))
        package = package_folder(get_root_dir(abs_package_path))
        isdir(package) || mkpath(package)
        precompile_file = joinpath(package, "precompile.jl")
        snoop(
            file2snoop,
            precompile_file,
            joinpath(package, "snooped.csv")
        )
        precompile_file
    end
    open(userimg, "w") do io
        for path in snooped_precompiles
            write(io, open(read, path))
            println(io)
        end
    end
    userimg
end
