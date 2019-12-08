module PackageCompilerX


# TODO: Add good debugging statements
# TODO: sysimage or sysimg...

using Base: active_project
using Libdl: Libdl
using Pkg: Pkg
using UUIDs: UUID
using DocStringExtensions: SIGNATURES, TYPEDEF

export create_sysimage, create_app, audit_app, restore_default_sysimg

include("juliaconfig.jl")

# TODO: Check more carefully how to just use mingw on windows without using cygwin.
function get_compiler()
    if Sys.iswindows()
        return `x86_64-w64-mingw32-gcc`
    else
        if Sys.which("gcc") !== nothing
            return `gcc`
        elseif Sys.which("clang") !== nothing
            return `clang`
        end
        error("could not find a compiler, looked for `gcc` and `clang`")
    end
end

# TODO: Be able to set target for -C?
# TODO: Change to commented default ?
# const DEFAULT_TARGET = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
const DEFAULT_TARGET = "generic"
current_process_sysimage_path() = unsafe_string(Base.JLOptions().image_file)

function get_julia_cmd()
    julia_path = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia_path --color=yes --startup-file=no --cpu-target=$DEFAULT_TARGET`
end

all_stdlibs() = readdir(Sys.STDLIB)

function rewrite_sysimg_jl_only_needed_stdlibs(stdlibs::Vector{String})
    sysimg_source_path = Base.find_source_file("sysimg.jl")
    sysimg_content = read(sysimg_source_path, String)
    # replaces the hardcoded list of stdlibs in sysimg.jl with
    # the stdlibs that is given as argument
    return replace(sysimg_content, r"stdlibs = \[(.*?)\]"s => string("stdlibs = [", join(":" .* string.(stdlibs), ",\n"), "]"))
end

function create_fresh_base_sysimage(stdlibs::Vector{String})
    tmp = mktempdir(cleanup=false)
    sysimg_source_path = Base.find_source_file("sysimg.jl")
    base_dir = dirname(sysimg_source_path)
    tmp_corecompiler_ji = joinpath(tmp, "corecompiler.ji")
    tmp_sys_ji = joinpath(tmp, "sys.ji")
    compiler_source_path = joinpath(base_dir, "compiler", "compiler.jl")

    @info "PackageCompilerX: creating base system image (incremental=false), this might take a while..."
    cd(base_dir) do
        # Create corecompiler.ji
        cmd = `$(get_julia_cmd()) --output-ji $tmp_corecompiler_ji -g0 -O0 $compiler_source_path`
        @debug "running $cmd"
        read(cmd)

        # Use that to create sys.ji
        new_sysimage_content = rewrite_sysimg_jl_only_needed_stdlibs(stdlibs)
        new_sysimage_source_path = joinpath(base_dir, "sysimage_packagecompiler_x.jl")
        write(new_sysimage_source_path, new_sysimage_content)
        try
            cmd = `$(get_julia_cmd()) --sysimage=$tmp_corecompiler_ji -g1 -O0 --output-ji=$tmp_sys_ji $new_sysimage_source_path`
            @debug "running $cmd"
            read(cmd)
        finally
            rm(new_sysimage_source_path; force=true)
        end
    end

    return tmp_sys_ji
end

# TODO: Add output file?
function run_precompilation_script(project::String, precompile_file::Union{String, Nothing})
    # TODO: Audit tempname usage
    tracefile = tempname()
    if precompile_file == nothing
        arg = `-e ''`
    else
        arg = `$precompile_file`
    end
    touch(tracefile)
    cmd = `$(get_julia_cmd()) --sysimage=$(current_process_sysimage_path()) --project=$project
            --compile=all --trace-compile=$tracefile $arg`
    @debug "run_precompilation_script: running $cmd"
    run(cmd)
    return tracefile
end

function create_sysimg_object_file(object_file::String, packages::Vector{Symbol};
                            project::String,
                            base_sysimg::String,
                            precompile_execution_file::Union{Vector{String}, Nothing},
                            precompile_statements_file::Union{Vector{String}, Nothing})
    # include all packages into the sysimg
    julia_code = """
        if !isdefined(Base, :uv_eventloop)
            Base.reinit_stdio()
        end
        Base.__init__(); 
        """
    for package in packages
        julia_code *= "using $package\n"
    end
    
    # handle precompilation
    precompile_statements = ""
    @debug "running precompilation execution script..."
    tracefiles = String[]
    for file in (precompile_execution_file === nothing ? (nothing,) : precompile_execution_file)
        tracefile = run_precompilation_script(project, file)
        precompile_statements *= "append!(precompile_statements, readlines($(repr(tracefile))))\n"
    end
    if precompile_statements_file != nothing
        for file in precompile_statements_file
            precompile_statements *= 
                "append!(precompile_statements, readlines($(repr(file))))\n"
        end
    end

    precompile_code = """
        # This @eval prevents symbols from being put into Main
        @eval Module() begin
            PrecompileStagingArea = Module()
            for (_pkgid, _mod) in Base.loaded_modules
                if !(_pkgid.name in ("Main", "Core", "Base"))
                    eval(PrecompileStagingArea, :(const \$(Symbol(_mod)) = \$_mod))
                end
            end
            precompile_statements = String[]
            $precompile_statements
            for statement in sort(precompile_statements)
                # println(statement)
                try
                    Base.include_string(PrecompileStagingArea, statement)
                catch
                    # See julia issue #28808
                    @error "failed to execute \$statement"
                end
            end
        end # module
        """
    julia_code *= precompile_code

    # finally, make julia output the resulting object file
    @debug "creating object file at $object_file"
    @info "PackageCompilerX: creating system image object file, this might take a while..."

    cmd = `$(get_julia_cmd()) --sysimage=$base_sysimg --project=$project --output-o=$(object_file) -e $julia_code`
    @debug "running $cmd"
    run(cmd)
end

default_sysimg_path() = joinpath(julia_private_libdir(), "sys." * Libdl.dlext)
default_sysimg_name() = basename(default_sysimg_path())
backup_default_sysimg_path() = default_sysimg_path() * ".backup"
backup_default_sysimg_name() = basename(backup_default_sysimg_path())

# TODO: Also check UUIDs for stdlibs, not only names
function gather_stdlibs_project(project::String)
    project_toml_path = abspath(Pkg.Types.projectfile_path(project; strict=true))
    ctx = Pkg.Types.Context(env=Pkg.Types.EnvCache(project_toml_path))
    @assert ctx.env.manifest !== nothing
    stdlibs = all_stdlibs()
    stdlibs_project = String[]
    for (uuid, pkg) in ctx.env.manifest
        if pkg.name in stdlibs
            push!(stdlibs_project, pkg.name)
        end
    end
    return stdlibs_project
end

"""
    $SIGNATURES
"""
function create_sysimage(packages::Union{Symbol, Vector{Symbol}};
                         sysimage_path::Union{String,Nothing}=nothing,
                         project::String=active_project(),
                         precompile_execution_file::Union{String, Vector{String}, Nothing}=nothing,
                         precompile_statements_file::Union{String, Vector{String}, Nothing}=nothing,
                         incremental::Bool=true,
                         filter_stdlibs=false,
                         replace_default::Bool=false)
    if sysimage_path === nothing
        if replace_default == false
            error("`sysimage_path` cannot be `nothing` if `replace_default` is `false`")
        end
        # We will replace the default sysimage so just put it somewhere for now
        tmp = mktempdir()
        sysimage_path = joinpath(tmp, string("sys.", Libdl.dlext))
    end

    if filter_stdlibs && incremental
        error("must use `incremental=false` to use `filter_stdlibs=true`")
    end

    # Functions lower down handles precompilation file as arrays so convert here
    packages = vcat(packages)
    precompile_execution_file !== nothing && (precompile_execution_file = vcat(precompile_execution_file))
    precompile_statements_file !== nothing && (precompile_statements = vcat(precompile_statements_file))

    if !incremental
        if filter_stdlibs
            stdlibs = gather_stdlibs_project(project)
        else
            stdlibs= all_stdlibs()
        end
        base_sysimg = create_fresh_base_sysimage(stdlibs)
    else
        base_sysimg = current_process_sysimage_path()
    end

    object_file = tempname() * ".o"
    create_sysimg_object_file(object_file, packages;
                              project=project,
                              base_sysimg=base_sysimg,
                              precompile_execution_file=precompile_execution_file,
                              precompile_statements_file=precompile_statements_file)
    create_sysimg_from_object_file(object_file, sysimage_path)
    if replace_default
        if !isfile(backup_default_sysimg_path())
            @debug "making a backup of default sysimg"
            cp(default_sysimg_path(), backup_default_sysimg_path())
        end
        @info "PackageCompilerX: default sysimg replaced, restart Julia for the new sysimg to be in effect"
        mv(sysimage_path, default_sysimg_path(); force=true)
    end
    # TODO: Remove object file
end

function create_sysimg_from_object_file(input_object::String, sysimage_path::String)
    julia_libdir = dirname(Libdl.dlpath("libjulia"))

    # Prevent compiler from stripping all symbols from the shared lib.
    # TODO: On clang on windows this is called something else
    if Sys.isapple()
        o_file = `-Wl,-all_load $input_object`
    else
        o_file = `-Wl,--whole-archive $input_object -Wl,--no-whole-archive`
    end
    extra = Sys.iswindows() ? `-Wl,--export-all-symbols` : ``
    run(`$(get_compiler()) -shared -L$(julia_libdir) -o $sysimage_path $o_file -ljulia $extra`)
    return nothing
end

"""
    $SIGNATURES

lalala
"""
function restore_default_sysimg()
    if !isfile(backup_default_sysimg_path())
        error("did not find a backup sysimg")
    end
    cp(backup_default_sysimg_path(), default_sysimg_path(); force=true)
    rm(backup_default_sysimg_path())
    @info "PackageCompilerX: default sysimg restored, restart Julia for the new sysimg to be in effect"
    return nothing
end

const REQUIRES = "Requires" => UUID("ae029012-a4dd-5104-9daa-d747884805df")

# Check for things that might indicate that the app or dependencies 
"""
    $SIGNATURES

Check for possible problems with regfards to relocatability at 
the project at `app_dir`.

!!! warning
    This cannot guarantee that the project is free of relocatability problems,
    it can only detect some known bad cases and warn about those.
"""
function audit_app(app_dir::String)
    project_toml_path = abspath(Pkg.Types.projectfile_path(app_dir; strict=true))
    ctx = Pkg.Types.Context(env=Pkg.Types.EnvCache(project_toml_path))
    return audit_app(ctx)
end
function audit_app(ctx::Pkg.Types.Context)
    # Check for Requires.jl usage
    if REQUIRES in ctx.env.project.deps
        @warn "Project has a dependency on Requires.jl, code in `@require` will not be run"
    end
    for (uuid, pkg) in ctx.env.manifest
        if REQUIRES in pkg.deps
            @warn "$(pkg.name) has a dependency on Requires.jl, code in `@require` will not be run"
        end
    end

    # Check for build script usage
    if isfile(joinpath(dirname(ctx.env.project_file), "deps", "build.jl"))
        @warn "Project has a build script, this might indicate that it is not relocatable"
    end
    pkgs = Pkg.Types.PackageSpec[]
    Pkg.Operations.load_all_deps!(ctx, pkgs)
    for pkg in pkgs
        pkg_source = Pkg.Operations.source_path(pkg)
        pkg_source === nothing && continue
        if isfile(joinpath(pkg_source, "deps", "build.jl"))
            @warn "Package $(pkg.name) has a build script, this might indicate that it is not relocatable"
        end
    end
    return
end

"""
    $SIGNATURES
"""
function create_app(package_dir::String,
                    app_dir::String;
                    precompile_execution_file::Union{String, Vector{String}, Nothing}=nothing,
                    precompile_statements_file::Union{String, Vector{String}, Nothing}=nothing,
                    incremental=false,
                    filter_stdlibs=false,
                    audit=true,
                    force=false)
    project_toml_path = abspath(Pkg.Types.projectfile_path(package_dir; strict=true))
    manifest_toml_path = abspath(Pkg.Types.manifestfile_path(package_dir))
    if manifest_toml_path === nothing
        @warn "it is not recommended to create an app without a preexisting manifest"
    end
    project_toml = Pkg.TOML.parsefile(project_toml_path)
    project_path = abspath(package_dir)
    app_name = get(project_toml, "name") do
        error("expected package to have a `name`-entry")
    end
    sysimg_file = app_name * "." * Libdl.dlext

    ctx = Pkg.Types.Context(env=Pkg.Types.EnvCache(project_toml_path))
    @debug "instantiating project at \"$project_toml_path\""
    Pkg.instantiate(ctx)
    
    if isdir(app_dir)
        if !force
            error("directory $(repr(app_dir)) already exists, use `force=true` to overwrite (will completely",
                  " remove the directory")
        end
        rm(app_dir; force=true, recursive=true)
    end

    audit && audit_app(ctx)
   
    mkpath(app_dir)

    bundle_julia_libraries(app_dir)
    bundle_artifacts(ctx, app_dir)

    # TODO: Create in a temp dir and then move it into place?
    binpath = joinpath(app_dir, "bin")
    mkpath(binpath)
    cd(binpath) do
                create_sysimage(Symbol(app_name); sysimage_path=sysimg_file, project=project_path, 
                                incremental=incremental, filter_stdlibs=filter_stdlibs,
                                precompile_execution_file = precompile_execution_file,
                                precompile_statements_file = precompile_statements_file)
        create_executable_from_sysimg(; sysimage_path=sysimg_file, executable_path=app_name)
        if Sys.isapple()
            cmd = `install_name_tool -change $sysimg_file @rpath/$sysimg_file $app_name`
            @debug "running $cmd"
            run(cmd)
        end
    end
    return
end

# This requires that the sysimg have been built so that there is a ccallable `julia_main`
# in Main.
function create_executable_from_sysimg(;sysimage_path::String,
                                        executable_path::String)
    flags = join((cflags(), ldflags(), ldlibs()), " ")
    flags = Base.shell_split(flags)
    wrapper = joinpath(@__DIR__, "embedding_wrapper.c")
    if Sys.iswindows()
        rpath = ``
    elseif Sys.isapple()
        rpath = `-Wl,-rpath,'@executable_path' -Wl,-rpath,'@executable_path/../lib'`
    else
        rpath = `-Wl,-rpath,\$ORIGIN:\$ORIGIN/../lib`
    end
    cmd = `$(get_compiler()) -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) -o $(executable_path) $(wrapper) $(sysimage_path) -O2 $rpath $flags`
    @debug "running $cmd"
    run(cmd)
    return nothing
end

function bundle_julia_libraries(app_dir)
    app_libdir = joinpath(app_dir, Sys.isunix() ? "lib" : "bin")
    cp(julia_libdir(), app_libdir; force=true)
    # We do not want to bundle the sysimg (nor the backup):
    rm(joinpath(app_libdir, "julia", default_sysimg_name()); force=true)
    rm(joinpath(app_libdir, "julia", backup_default_sysimg_name()); force=true)
    return
end

function bundle_artifacts(ctx, app_dir)
    @debug "bundling artifacts..."

    pkgs = Pkg.Types.PackageSpec[]
    Pkg.Operations.load_all_deps!(ctx, pkgs)

    # Also want artifacts for the project itself
    if ctx.env.pkg !== nothing
        # This is kinda ugly...
        ctx.env.pkg.path = dirname(ctx.env.project_file)
        push!(pkgs, ctx.env.pkg)
    end

    # Collect all artifacts needed for the project
    artifact_paths = String[]
    for pkg in pkgs
        pkg_source_path = Pkg.Operations.source_path(pkg)
        pkg_source_path === nothing && continue
        # Check to see if this package has an (Julia)Artifacts.toml
        for f in Pkg.Artifacts.artifact_names
            artifacts_toml_path = joinpath(pkg_source_path, f)
            if isfile(artifacts_toml_path)
                @debug "bundling artifacts for $(pkg.name)"
                artifact_dict = Pkg.Artifacts.load_artifacts_toml(artifacts_toml_path)
                for name in keys(artifact_dict)
                    @debug "  \"$name\""
                    push!(artifact_paths, Pkg.Artifacts.ensure_artifact_installed(name, artifacts_toml_path))
                end
                break
            end
        end
    end

    # Copy the artifacts needed to the app directory
    artifact_app_path = joinpath(app_dir, "artifacts")
    if !isempty(artifact_paths)
        mkpath(artifact_app_path)
    end
    for artifact_path in artifact_paths
        artifact_name = basename(artifact_path)
        # force=true?
        cp(artifact_path, joinpath(artifact_app_path, artifact_name))
    end
    return
end

end # module
