using Pkg, Serialization


const packages_needing_initialization = Symbol[]

"""
    init_package!(packages::Symbol...)
Globally add `packages` to the list of packages that need their `__init__`
method called when ahead of time compiling.

(adds it only for the current session).
"""
function init_package!(packages::Symbol...)
    push!(packages_needing_initialization, packages...)
    # TODO use set?!
    unique!(packages_needing_initialization)
end

const known_blacklisted_packages = Symbol[]

# Some packages directly depend on Homebrew/QuartzImageIO, even on non apple systems,
# Which yields an annoying warning compiled directly into the system image.
if !Sys.isapple()
    push!(known_blacklisted_packages, :QuartzImageIO, :Homebrew)
end


"""
    blacklist!(packages::Symbol...)
Globally blacklists a package that is known to not ahead of time compile.
(Blacklists only for the current session).
"""
function blacklist!(packages::Symbol...)
    push!(known_blacklisted_packages, packages...)
    unique!(known_blacklisted_packages)
end


function snoop(snoopfile::String, output_io::IO; verbose = false)

    # make sure our variables don't conflict with any precompile statements
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
    project = snoop2root(snoopfile) === nothing ? "" : snoop2root(snoopfile)
    @show project
    run_julia(command, compile = "all", O = 0, g = 1, trace_compile = tmp_file, project = project)
    line_idx = 0; missed = 0
    println(output_io, "global _precompiles_actually_executed = 0")
    debug = verbose ? "@info" : "@debug"
    for line in eachline(tmp_file)
        line_idx += 1
        # replace function instances, which turn up as typeof(func)().
        # TODO why would they be represented in a way that doesn't actually work?
        line = replace(line, r"typeof\(([\u00A0-\uFFFF\w_!´\.]*@?[\u00A0-\uFFFF\w_!´]+)\)\(\)" => s"\1")
        # Is this ridicilous? Yes, it is! But we need a unique symbol to replace `_`,
        # which otherwise ends up as an uncatchable syntax error
        line = replace(line, r"\b_\b" => "🐃")
        # replace ##symbols
        #line = replace(line, r"(?!\")(##.*?#\d+?)(?!\")" => s"eval(Symbol(\"\1\"))")

        # replace character literals in type paramters, which can't be constructed from their data
        line = replace(line, r"Char\((0x[\da-f]{8})\)" => s"reinterpret(Char, \1)")

        try
            expr = Meta.parse(line, raise = true)
            if expr.head != :incomplete
                # after all this, we still need to wrap into try catch,
                # since some anonymous symbols won't be found...
                println(output_io,
                    "try; global _precompiles_actually_executed; $line;",
                    "_precompiles_actually_executed += 1 ;catch e;",
                    "$debug \"couldn't precompile statement $line_idx\" exception = e; end"
                )
            else
                missed += 1
                verbose && @info "Incomplete line in precompile file: $line"
            end
        catch e
            missed += 1
            verbose && @info "Parse error in precompile file: $line" exception=e
        end
    end
    verbose && println(output_io, """@info("successfully executed \$(_precompiles_actually_executed) lines out of $line_idx")""")
    verbose && @info "used $(line_idx - missed) out of $line_idx precompile statements"
end

function resolved_blacklist(ctx)
    specs = PackageSpec.(string.(known_blacklisted_packages))
    resolve_packages!(ctx, specs)
    return Set(specs)
end

function prepr(pspec)
    "Base.PkgId(Base.$(repr(pspec.uuid)), $(repr(pspec.name)))"
end

function snoop_packages(
        packages::Vector{String}, file::String;
        install::Bool = false, verbose = false
    )
    pkgs = PackageSpec.(packages)
    snoopfiles = get_snoopfile.(pkgs)
    packages = flat_deps(packages)

    union!(packages, test_dependencies(pkgs))

    # remove blacklisted packages from full list of packages
    imports = setdiff(packages, resolved_blacklist(Pkg.Types.Context()))
    inits = string.(packages_needing_initialization)
    usings = join(["const $(x.name) = Base.require($(prepr(x)))" for x in imports], "\n")
    inits = join("    " .* inits, ",\n")
    open(file, "w") do io
        println(io, """
        $usings
        __init_modules = [
        $inits
        ]

        for Mod in __init_modules
            isdefined(Mod, :__init__) && Mod.__init__()
        end
        """)
        for file in snoopfiles
            snoop(file, io; verbose = verbose)
        end
    end
end
