using Pkg, Serialization


const packages_needing_initialization = [:GR, :Unitful]

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
"""
    blacklist!(packages::Symbol...)
Globally blacklists a package that is known to not ahead of time compile.
(Blacklists only for the current session).
"""
function blacklist!(packages::Symbol...)
    push!(known_blacklisted_packages, packages...)
    unique!(known_blacklisted_packages)
end

blacklist!(:WinRPM, :HTTPClient)
# Some packages directly depend on Homebrew/QuartzImageIO, even on non apple systems,
# Which yields an annoying warning compiled directly into the system image.
if !Sys.isapple()
    blacklist!(:QuartzImageIO, :Homebrew)
end

function needs_init(pkg_spec)
    Symbol(pkg_spec.name) in packages_needing_initialization
end
function use_package(io, pkg_spec)
    name = pkg_spec.name
    print(io, """
    if !(@isdefined $name)
        const $name = Base.require($(prepr(pkg_spec)))
    """
    )
    if needs_init(pkg_spec)
        println(io, "    isdefined($name, :__init__) && $name.__init__()")
    end
    println(io, "end")
end

function append_usings(io::IO, pkgs)
    # Remove blacklisted packages
    filter!(x-> !(Symbol(x.name) in PackageCompiler.known_blacklisted_packages), pkgs)
    for pkg in pkgs
        PackageCompiler.use_package(io, pkg)
    end
    println(io)
end
"""
    snoop(snoopfile::String, outfile::String; verbose = false)

Runs snoopfile and records all called functions as precompile statements in
`outfile`.
"""
function snoop(snoopfile::String, outfile::String; verbose = false)
    open(outfile, "w") do io
        snoop(snoopfile, io; verbose = verbose)
    end
end

function snoop(snoopfile::String, output_io::IO; verbose = false)

    # make sure our variables don't conflict with any precompile statements
    command = """
    # let's wrap the snoop file in a try catch...
    # This way we still do some snooping even if there is an error in the tests!
    try
        include($(repr(snoopfile)))
    catch e
        @warn("Snoop file errored. Precompile statements were recorded until error!", exception = e)
    end
    """
    # let's use a file in the PackageCompiler dir,
    # so it doesn't get lost if later steps fail
    tmp_file = package_folder("precompile_tmp.jl")
    # Use current project for snooping!
    run_julia(command, compile = "all", O = 0, g = 1, trace_compile = tmp_file, project = current_project())
    line_idx = 0; missed = 0
    tmp_io = IOBuffer()
    println(tmp_io, "global _precompiles_actually_executed = 0")
    packages = Set{String}()
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
                union!(packages, extract_used_modules(line))
                println(tmp_io,
                    "try; global _precompiles_actually_executed; $line || error(\"Failed to precompile\");",
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
    verbose && println(tmp_io, """@info("successfully executed \$(_precompiles_actually_executed) lines out of $line_idx")""")
    used_packages = resolve_packages(Pkg.Types.Context(), collect(packages), true)
    append_usings(output_io, used_packages)
    write(output_io, take!(tmp_io))
    verbose && @info "used $(line_idx - missed) out of $line_idx precompile statements"
end

"""
    to_pkgid(pspec::Pkg.Types.PackageSpec)
PackageSpec has bad hashing behavior, so we use PkgId in places
"""
to_pkgid(pspec::Pkg.Types.PackageSpec) = Base.PkgId(pspec.uuid, pspec.name)

function resolved_list(ctx, list)
    result = Set{Base.PkgId}()
    for pkg in list
        pid = resolve_package(ctx, string(pkg))
        # Don't add unknown packages
        if pid === nothing
            if !(pkg in (:QuartzImageIO, :Homebrew))
                # we added the above packages per default..If they're not resolved it's fine
                # Otherwise it may indicate user error, so we issue a warning:
                @warn("Package $pkg could be resolved, so it can't be blacklisted")
            end
        else
            push!(result, pid)
        end
    end
    return result
end

function resolved_blacklist(ctx)
    resolved_list(ctx, known_blacklisted_packages)
end

function resolved_inits(ctx)
    resolved_list(ctx, packages_needing_initialization)
end

function prepr(pspec)
    "Base.PkgId(Base.$(repr(pspec.uuid)), $(repr(pspec.name)))"
end

function snoop_packages(
        packages::Vector{String}, file::String;
        install::Bool = false, verbose::Bool = false
    )
    ctx = Pkg.Types.Context()
    pkgs = PackageSpec.(packages)
    snoopfiles = get_snoopfile.(pkgs)
    packages = flat_deps(ctx, packages)
    direct_test_deps = test_dependencies(pkgs)
    missing_pkgs = not_installed(Types.PackageSpec[direct_test_deps...])
    if install && !isempty(missing_pkgs)
        Pkg.API.add(ctx, missing_pkgs)
    elseif isempty(missing_pkgs)
        @warn("The following test dependencies are not installed: $missing_pkgs.
        Snooping based on test scripts will likely fail.
        Please use `install = true` or install those packages manually")
    end
    # get all recursive test deps:
    union!(packages, flat_deps(ctx, direct_test_deps))
    # remove blacklisted packages from full list of packages
    imports = setdiff(to_pkgid.(packages), resolved_blacklist(ctx))
    inits = intersect(imports, resolved_inits(ctx))
    usings = join(["const $(x.name) = Base.require($(prepr(x)))" for x in imports], "\n")
    inits = join("    " .* getfield.(inits, :name), ",\n")
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
