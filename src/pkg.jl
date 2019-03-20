using Pkg
using Pkg: TOML
using Pkg: Operations, Types, API
using UUIDs

#=
genfile & create_project_from_require have been taken from the PR
https://github.com/JuliaLang/PkgDev.jl/pull/144
which was created by https://github.com/KristofferC

THIS IS JUST A TEMPORARY SOLUTION FOR PACKAGES WITHOUT A TOML AND WILL GET MOVED OUT!
=#

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

function isinstalled(pkg::Types.PackageSpec, installed = Pkg.installed())
    root_path(pkg) === nothing && return false
    return haskey(installed, pkg.name)
end

function only_installed(pkgs::Vector{Types.PackageSpec})
    installed = Pkg.installed()
    filter(p-> isinstalled(p, installed), pkgs)
end
function not_installed(pkgs::Vector{Types.PackageSpec})
    installed = Pkg.installed()
    filter(p-> !isinstalled(p, installed), pkgs)
end

function root_path(pkg::Types.PackageSpec)
    path = Base.locate_package(Base.PkgId(pkg.uuid, pkg.name))
    path === nothing && return nothing
    return abspath(joinpath(dirname(path)), "..")
end

function test_dependencies!(pkgs::Vector{Types.PackageSpec}, result = Dict{Base.UUID, Types.PackageSpec}())
    for pkg in pkgs
        test_dependencies!(root_path(pkg), result)
    end
    return result
end

function test_dependencies!(pkg_root, result = Dict{Base.UUID, Types.PackageSpec}())
    testreq = joinpath(pkg_root, "test", "REQUIRE")
    toml = joinpath(pkg_root, "Project.toml")
    if isfile(toml)
        pkgs = get(TOML.parsefile(toml), "extras", nothing)
        if pkgs !== nothing
            return Dict((uuid => PackageSpec(name = n, uuid = uuid) for (n, uuid) in pkgs))
        end
    end
    if isfile(testreq)
        deps = packages_from_require(testreq)
        return Dict((d.uuid => d for d in deps))
    end
    result
end

get_snoopfile(pkg::Types.PackageSpec) = get_snoopfile(root_path(pkg))

function get_snoopfile(pkg_root::String)
    paths = (
        joinpath(pkg_root,"snoopfile.jl"),
        joinpath(pkg_root, "snoop", "snoopfile.jl"),
        joinpath(pkg_root, "src", "snoopfile.jl"),
        joinpath(pkg_root, "test", "runtests.jl")
    )
    idx = findfirst(isfile, paths)
    idx === nothing && error("No snoopfile or testfile found for package $pkg_root")
    return paths[idx]
end

function package_fullspec(ctx, uuid)
    if Types.is_project_uuid(ctx.env, uuid)
        path = dirname(ctx.env.project_file)
        hash_or_path = path
        name = ctx.env.pkg.name
    else
        entry = API.manifest_info(ctx.env, uuid)
        name = entry.name
    end
    return PackageSpec(name = name, uuid = uuid)
end

function direct_dependencies!(ctx::Types.Context, pkgs::Vector{Types.PackageSpec}, deps = Dict{Base.UUID, Types.PackageSpec}())
    resolve_packages!(ctx, pkgs)
    for pkg in pkgs
        pkg.uuid in keys(ctx.stdlibs) && continue
        haskey(deps, pkg.uuid) && continue
        deps[pkg.uuid] = pkg
        if Types.is_project(ctx.env, pkg)
            pkgs = [PackageSpec(name, uuid) for (name, uuid) in ctx.env.project.deps]
        else
            info = API.manifest_info(ctx.env, pkg.uuid)
            if info === nothing
                API.pkgerror("could not find manifest info for package $(pkg.name) with uuid: $(pkg.uuid)")
            end
            pkgs = [PackageSpec(name, uuid) for (name, uuid) in info.deps]
        end
        direct_dependencies!(ctx, pkgs, deps)
    end
    return deps
end

function resolve_packages!(ctx, pkgs)
    for pkg in pkgs
        pkg.mode = PKGMODE_MANIFEST
    end
    API.project_resolve!(ctx.env, pkgs)
    API.manifest_resolve!(ctx.env, pkgs)
    API.ensure_resolved(ctx.env, pkgs)
end


"""
Resolves all dependencies of a list of packages, including test and recursive
Dependencies.
"""
function resolve_full_dependencies(pkgs::Vector{Types.PackageSpec}, ctx = Types.Context())
    # Hm the set is bugged due to it not having the right hashing function
    # I'll leave it as a set for now, and just do some tricks in the end to make
    # elements unique
    tdeps = test_dependencies!(pkgs)
    union!(pkgs, values(tdeps)) # add to pkgs, so we get also their recursive deps
    ddeps = direct_dependencies!(ctx, pkgs)
    union!(pkgs, values(ddeps))
    deps_unique = Dict{UUID, Types.PackageSpec}((x.uuid => x for x in pkgs))
    collect(values(deps_unique))
end
