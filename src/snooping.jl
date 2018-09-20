using Pkg, Serialization

# Taken from SnoopCompile, modifying just `julia_cmd`
function snoop_vanilla(flags, filename, commands, pwd)
    println("Launching new julia process to run commands...")
    # addprocs will run the unmodified version of julia, so we
    # launch it as a command.
    code_object = """
            using Serialization
            while !eof(stdin)
                Core.eval(Main, deserialize(stdin))
            end
            """
    julia_cmd = build_julia_cmd(
        get_backup!(false, nothing), nothing, nothing, nothing, nothing, nothing,
        nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing
    )
    process = open(Cmd(`$julia_cmd $flags --eval $code_object`, dir=pwd), stdout, write=true)
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

function snoop(path, compilationfile, csv, subst, blacklist)
    csv = String(abspath(csv))
    execpath = String(abspath(path))
    snoop_vanilla(String[], csv, :(include($execpath)), dirname(execpath))
    data = SnoopCompile.read(csv)
    #pc = SnoopCompile.parcel(reverse!(data[2]))
    pc = SnoopCompile.format_userimg(reverse!(data[2]), subst=subst, blacklist=blacklist)
    pc = map(x -> "try; $x; catch ex; @warn \"\"\"skipping line: $(repr(x)).\"\"\" exception=ex; end\n", pc)
    SnoopCompile.write(compilationfile, pc)
    nothing
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
            Pkg.dir(package) # FIXME for Julia 1.0 this is deprecated (it should use `Base.find_package(package)` now)
        end
        file2snoop = normpath(abspath(joinpath(abs_package_path, snoopfile)))
        package = package_folder(get_root_dir(abs_package_path))
        isdir(package) || mkpath(package)
        precompile_file = joinpath(package, "precompile.jl")
        snoop(file2snoop, precompile_file, joinpath(package, "snooped.csv"),
            Vector{Pair{String, String}}(), String["Main"])
        return precompile_file
    end
    # merge all of the temporary files into a single output
    open(userimg, "w") do output
        println(output, """
            # Prevent this from being put into the Main namespace
            Core.eval(Module(), quote
            """)
        for (pkg, _) in packages
            println(output, """
                import $pkg
                """)
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
        println(output, """
            end) # eval
            """)
    end
    nothing
end
