using Pkg
using Pkg: TOML

const manifest_memoize = Ref{Dict{String, Any}}()

function current_manifest()
    if !isassigned(manifest_memoize)
        manifest_memoize[] = TOML.parsefile(replace(Base.active_project(), "Project.toml" => "Manifest.toml"))
    end
    return manifest_memoize[]
end

"""
Looks up the UUID of a package from the current manifest file
"""
function package_uuid(name::AbstractString, manifest::Dict = current_manifest())
    haskey(manifest, name) || error("Package $name not found in current manifest")
    pkg = manifest[name]
    isempty(pkg) && error("Package $name exist in manifest, but array is empty - faulty manifest?")
    length(pkg) > 1 && @warn "There are multiple packages for $name installed. Choosing first!"
    Base.UUID(first(pkg)["uuid"])
end
function in_manifest(name::AbstractString, manifest::Dict = current_manifest())
    haskey(manifest, name) || return false
end


"""
    require_uninstalled(name::AbstractString, mod = Main)

Loads a package, even if it isn't installed.
Call this only in a precompile file used for incremental compilation!
"""
function require_uninstalled(name::AbstractString, mod = Main)
    pkg = Base.PkgId(package_uuid(name), name)
    psym = Symbol(name)
    @eval mod begin
        if !isdefined($mod, $(QuoteNode(psym)))
            const $psym = Base.require($pkg)
            # we need to call the __init__ because of
            # https://github.com/JuliaLang/julia/issues/22910
            if isdefined($psym, :__init__)
                $psym.__init__()
            end
        else
            @warn(string($name, " already defined"))
        end
    end
end


function extract_used_packages(file::String)
    scope_regex = r"([\u00A0-\uFFFF\w_!´]*@?[\u00A0-\uFFFF\w_!´]+)\."
    namespaces = unique(getindex.(eachmatch(scope_regex, read(file, String)), 1))
    # only use names that are also in current manifest
    return filter(in_manifest, namespaces)
end


"""
Extracts using statements from a julia file.
"""
function extract_using(path, usings = Set{String}())
    src = read(path, String)
    regex = r"using ([\u00A0-\uFFFF\w_!´]+)(,[ \u00A0-\uFFFF\w_!´]+)?"
    for match in eachmatch(regex, src)
        push!(usings, match[1])
        if match[2] !== nothing
            pkgs = strip.(split(match[2], ',', keepempty = false))
            union!(usings, pkgs)
        end
    end
    return usings
end

#=
genfile & create_project_from_require have been taken from the PR
https://github.com/JuliaLang/PkgDev.jl/pull/144
which was created by https://github.com/KristofferC

THIS IS JUST A TEMPORARY SOLUTION FOR PACKAGES WITHOUT A TOML AND WILL GET MOVED OUT!
=#

using Pkg: Operations, Types
using UUIDs


function packages_from_require(reqfile::String)
    ctx = Pkg.Types.Context()
    pkgs = Types.PackageSpec[]
    compatibility = Pair{String, String}[]
    for r in Pkg.Pkg2.Reqs.read(reqfile)
        r isa Pkg.Pkg2.Reqs.Requirement || continue
        r.package == "julia" && continue
        push!(pkgs, Types.PackageSpec(r.package))
        intervals = r.versions.intervals
        if length(intervals) != 1
            @warn "Project.toml creator cannot handle multiple requirements for $(r.package), ignoring"
        else
            l = intervals[1].lower
            h = intervals[1].upper
            if l != v"0.0.0-"
                # no upper bound
                if h == typemax(VersionNumber)
                    push!(compatibility, r.package => string(">=", VersionNumber(l.major, l.minor, l.patch)))
                else # assume semver
                    push!(compatibility, r.package => string(">=", VersionNumber(l.major, l.minor, l.patch), ", ",
                                                             "<", VersionNumber(h.major, h.minor, h.patch)))
                end
            end
        end
    end
    Operations.registry_resolve!(ctx.env, pkgs)
    Operations.ensure_resolved(ctx.env, pkgs)
    pkgs
end
function create_project_from_require(pkgname::String, path::String, toml_path::String)
    ctx = Pkg.Types.Context()
    # Package data
    path = abspath(path)
    mainpkg = Types.PackageSpec(pkgname)
    Pkg.Operations.registry_resolve!(ctx.env, [mainpkg])
    if !Operations.has_uuid(mainpkg)
        uuid = UUIDs.uuid1()
        @info "Unregistered package $pkgname, giving it a new UUID: $uuid"
        mainpkg.version = v"0.1.0"
    else
        uuid = mainpkg.uuid
        @info "Registered package $pkgname, using already given UUID: $(mainpkg.uuid)"
        Pkg.Operations.set_maximum_version_registry!(ctx.env, mainpkg)
        v = mainpkg.version
        # Remove the build
        mainpkg.version = VersionNumber(v.major, v.minor, v.patch)
    end
    # Dependency data
    dep_pkgs = Types.PackageSpec[]
    test_pkgs = Types.PackageSpec[]
    compatibility = Pair{String, String}[]

    reqfiles = [joinpath(path, "REQUIRE"), joinpath(path, "test", "REQUIRE")]
    for (reqfile, pkgs) in zip(reqfiles, [dep_pkgs, test_pkgs])
        if isfile(reqfile)
            append!(pkgs, packages_from_require(reqfile))
        end
    end

    stdlib_deps = Pkg.Operations.find_stdlib_deps(ctx, path)
    for (stdlib_uuid, stdlib) in stdlib_deps
        pkg = Types.PackageSpec(stdlib, stdlib_uuid)
        if stdlib == "Test"
            push!(test_pkgs, pkg)
        else
            push!(dep_pkgs, pkg)
        end
    end

    # Write project

    project = Dict(
        "name" => pkgname,
        "uuid" => string(uuid),
        "version" => string(mainpkg.version),
        "deps" => Dict(pkg.name => string(pkg.uuid) for pkg in dep_pkgs)
    )

    if !isempty(compatibility)
        project["compat"] =
            Dict(name => ver for (name, ver) in compatibility)
    end

    if !isempty(test_pkgs)
        project["extras"] = Dict(pkg.name => string(pkg.uuid) for pkg in test_pkgs)
        project["targets"] = Dict("test" => [pkg.name for pkg in test_pkgs])
    end

    open(toml_path, "w") do io
        Pkg.TOML.print(io, project, sorted=true, by=key -> (Types.project_key_order(key), key))
    end
end

function package_toml(package::Symbol)
    pstr = string(package)
    pkg = Base.PkgId(package_uuid(pstr), pstr)
    # could use eval using here?! Not sure what is actually better
    pkg_module = Base.require(pkg)
    pkg_root = normpath(joinpath(dirname(pathof(pkg_module)), ".."))
    toml = joinpath(pkg_root, "Project.toml")
    runtests = joinpath(pkg_root, "test", "runtests.jl")
    # We will create a new toml, based that will include all test dependencies etc
    # We're also using the precompile toml as a temp toml for packages not having a toml
    precompile_toml = package_folder(pstr, "Project.toml")
    isdir(dirname(precompile_toml)) || mkpath(dirname(precompile_toml))
    test_deps = Dict()
    if !isfile(toml)
        create_project_from_require(pstr, pkg_root, precompile_toml)
    else
        testreq = joinpath(pkg_root, "test", "REQUIRE")
        if isfile(testreq)
            pkgs = packages_from_require(testreq)
            test_deps = Dict(pkg.name => string(pkg.uuid) for pkg in pkgs)
        end
        cp(toml, precompile_toml, force = true)
    end

    toml = TOML.parsefile(precompile_toml)

    deps = merge(get(toml, "deps", Dict()), test_deps)
    # Add the package itself
    deps[toml["name"]] = toml["uuid"]
    # Add the packages we need
    deps["Pkg"] = string(package_uuid("Pkg"))
    deps["PackageCompiler"] = string(package_uuid("PackageCompiler"))

    test_deps = get(toml, "extras", Dict())
    compile_toml = Dict()
    compile_toml["name"] = string(package, "Precompile")
    compile_toml["deps"] = merge(test_deps, deps)
    if haskey(toml, "compat")
        compile_toml["compat"] = toml["compat"]
    end
    open(precompile_toml, "w") do io
        TOML.print(
            io, compile_toml,
            sorted = true, by = key-> (Types.project_key_order(key), key)
        )
    end
    # Manifest needs to be newly generated, so rm it to not get stuck with an old one
    if isfile(package_folder(pstr, "Manifest.toml"))
        rm(package_folder(pstr, "Manifest.toml"))
    end
    precompile_toml, runtests
end
