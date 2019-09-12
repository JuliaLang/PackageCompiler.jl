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
    # could use eval using here?! Not sure what is actually better
    pkg_module = Base.require(Module(), package)
    pkg_root = normpath(joinpath(dirname(pathof(pkg_module)), ".."))
    toml = joinpath(pkg_root, "Project.toml")
    # Check for snoopfile and fall back to runtests.jl
    # if it can't be found
    snoopfile = get_snoopfile(pkg_root)
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
        chmod(precompile_toml, 0o644)
    end
    # remove any old manifest
    if isfile(package_folder(pstr, "Manifest.toml"))
        rm(package_folder(pstr, "Manifest.toml"))
    end
    # add ourselves as dependencies and ensure we have a manifest
    run_julia("""
    using Pkg
    Pkg.instantiate()
    pkg"add PackageCompiler Pkg"
    """, project = precompile_toml, startup_file = "no")

    toml = TOML.parsefile(precompile_toml)

    deps = merge(get(toml, "deps", Dict()), test_deps)
    # Add the package itself
    deps[toml["name"]] = toml["uuid"]
    # Add the packages we need
    test_deps = get(toml, "extras", Dict())
    compile_toml = Dict()
    compile_toml["name"] = string(package, "Precompile")
    compile_toml["deps"] = merge(test_deps, deps)
    if haskey(toml, "compat")
        compile_toml["compat"] = toml["compat"]
    end
    write_toml(precompile_toml, compile_toml)
    precompile_toml, snoopfile
end

function write_toml(path, dict)
    open(path, "w") do io
        TOML.print(
            io, dict,
            sorted = true, by = key-> (Types.project_key_order(key), key)
        )
    end
end

function get_snoopfile(pkg_root)
    snoopfileroot = joinpath(pkg_root,"snoopfile.jl")
    snoopfilesnoopdir = joinpath(pkg_root, "snoop", "snoopfile.jl")
    snoopfilesrc = joinpath(pkg_root, "src", "snoopfile.jl")
    if isfile(snoopfileroot)
        snoopfile = snoopfileroot
    elseif isfile(snoopfilesnoopdir)
        snoopfile = snoopfilesnoopdir
    elseif isfile(snoopfilesrc)
        snoopfile = snoopfilesrc
    else
        snoopfile = joinpath(pkg_root, "test", "runtests.jl")
    end
    return snoopfile
end
