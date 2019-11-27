module PackageCompilerX

# TODO: Add good debugging statements

using Base: active_project
using Libdl: Libdl
using Pkg: Pkg

if isdefined(Pkg, :Artifacts)
    const SUPPORTS_ARTIFACTS = true
else
    const SUPPORTS_ARTIFACTS = false
end

include("juliaconfig.jl")

# TODO: Check more carefully how to just use mingw on windows without using cygwin.
const CC = (Sys.iswindows() ? `x86_64-w64-mingw32-gcc` : `gcc`)

function get_julia_cmd()
    julia_path = joinpath(Sys.BINDIR, Base.julia_exename())
    image_file = unsafe_string(Base.JLOptions().image_file)
    cmd = `$julia_path -J$image_file --color=yes --startup-file=no -Cnative`
end

# TODO: Add output file?
# Returns a vector of precompile statemenets
function run_precompilation_script(project::String, precompile_file::String)
    tracefile = tempname()
    julia_code = """Base.__init__(); include($(repr(precompile_file)))"""
    cmd = `$(get_julia_cmd()) --project=$project --trace-compile=$tracefile -e $julia_code`
    @debug "run_precompilation_script: running $cmd"
    run(cmd)
    return tracefile
end

function create_object_file(object_file::String, packages::Union{Symbol, Vector{Symbol}};
                            project::String=active_project(),
                            precompile_execution_file::Union{String, Nothing}=nothing,
                            precompile_statements_file::Union{String, Nothing}=nothing)
    # include all packages into the sysimage
    packages = vcat(packages)
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
    if precompile_execution_file !== nothing || precompile_statements_file !== nothing
        precompile_statements = ""
        if precompile_execution_file !== nothing
            @debug "running precompilation execution script..."
            tracefile = run_precompilation_script(project, precompile_execution_file)
            precompile_statements *= "append!(precompile_statements, readlines($(repr(tracefile))))\n"
        end
        if precompile_statements_file != nothing
            precompile_statements *= "append!(precompile_statements, readlines($(repr(precompile_statements_file))))\n"
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
    end

    # finally, make julia output the resulting object file
    @debug "creating object file at $object_file"
    @info "PackageCompilerX: creating object file, this might take a while..."
    cmd = `$(get_julia_cmd()) --project=$project --output-o=$(object_file) -e $julia_code`
    @debug "running $cmd"
    run(cmd)
end

default_sysimage_path() = joinpath(julia_private_libdir(), "sys." * Libdl.dlext)
default_sysimage_name() = basename(default_sysimage_path())
backup_default_sysimage_path() = default_sysimage_path() * ".backup"
backup_default_sysimage_name() = basename(backup_default_sysimage_path())

function create_sysimage(packages::Union{Symbol, Vector{Symbol}}=Symbol[];
                         sysimage_path::Union{String,Nothing}=nothing,
                         project::String=active_project(),
                         precompile_execution_file::Union{String, Nothing}=nothing,
                         precompile_statements_file::Union{String, Nothing}=nothing,
                         replace_default_sysimage::Bool=false)
    if sysimage_path === nothing && replace_default_sysimage == false
        error("`sysimage_path` cannot be `nothing` if `replace_default_sysimage` is `false`")
    end
    if sysimage_path === nothing
        sysimage_path = string(tempname(), ".", Libdl.dlext)
    end

    object_file = tempname() * ".o"
    create_object_file(object_file, packages;
                       project=project, 
                       precompile_execution_file=precompile_execution_file,
                       precompile_statements_file=precompile_statements_file)
    create_sysimage_from_object_file(object_file, sysimage_path)
    if replace_default_sysimage
        if !isfile(backup_default_sysimage_path())
            @debug "making a backup of default sysimage"
            cp(default_sysimage_path(), backup_default_sysimage_path())
        end
        @info "PackageCompilerX: default sysimage replaced, restart Julia for the new sysimage to be in effect"
        cp(sysimage_path, default_sysimage_path(); force=true)
    end
    # TODO: Remove object file
end

function create_sysimage_from_object_file(input_object::String, sysimage_path::String)
    julia_libdir = dirname(Libdl.dlpath("libjulia"))

    # Prevent compiler from stripping all symbols from the shared lib.
    # TODO: On clang on windows this is called something else
    if Sys.isapple()
        o_file = `-Wl,-all_load $input_object`
    else
        o_file = `-Wl,--whole-archive $input_object -Wl,--no-whole-archive`
    end
    extra = Sys.iswindows() ? `-Wl,--export-all-symbols` : ``
    run(`$CC -shared -L$(julia_libdir) -o $sysimage_path $o_file -ljulia $extra`)
    return nothing
end

function restore_default_sysimage()
    if !isfile(backup_default_sysimage_path())
        error("did not find a backup sysimage")
    end
    cp(backup_default_sysimage_path(), default_sysimage_path(); force=true)
    rm(backup_default_sysimage_path())
    @info "PackageCompilerX: default sysimage restored, restart Julia for the new sysimage to be in effect"
    return nothing
end

# This requires that the sysimage have been built so that there is a ccallable `julia_main`
# in Main.
function create_executable_from_sysimage(;sysimage_path::String,
                                         executable_path::String)
    flags = join((cflags(), ldflags(), ldlibs()), " ")
    flags = Base.shell_split(flags)
    wrapper = joinpath(@__DIR__, "embedding_wrapper.c")
     if Sys.iswindows()
        rpath = ``
    elseif Sys.isapple()
        # TODO: Only add `../julia` when bundling
        rpath = `-Wl,-rpath,@executable_path:@executable_path/../lib`
    else
        rpath = `-Wl,-rpath,\$ORIGIN:\$ORIGIN/../lib`
    end
    cmd = `$CC -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) -o $(executable_path) $(wrapper) $(sysimage_path) -O2 $rpath $flags`
    @debug "running $cmd"
    run(cmd)
    return nothing
end

function create_app(package_dir::String,
                    app_dir::String,
                    precompile_execution_file::Union{String,Nothing}=nothing,
                    precompile_statements_file::Union{String,Nothing}=nothing,
                    # sysimage_path::Union{String,Nothing}=nothing, # optional sysimage
                    bundle=true,
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
    sysimage_file = app_name * "." * Libdl.dlext

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
   
    mkpath(app_dir)

    if bundle
        bundle_julia_libraries(app_dir)
        if SUPPORTS_ARTIFACTS
            bundle_artifacts(ctx, app_dir)
        end
    end

    # TODO: Maybe avoid this cd?
    cd(app_dir) do
        create_sysimage(Symbol(app_name); sysimage_path=sysimage_file, project=project_path)
        mkpath("bin")
        create_executable_from_sysimage(; sysimage_path=sysimage_file, executable_path=joinpath("bin", app_name))
        mv(sysimage_file, joinpath("bin", sysimage_file))
    end
    return
end

function bundle_julia_libraries(app_dir)
    app_libdir = joinpath(app_dir, Sys.isunix() ? "lib" : "bin")
    cp(julia_libdir(), app_libdir; force=true)
    # We do not want to bundle the sysimage (nor the backup):
    rm(joinpath(app_libdir, "julia", default_sysimage_name()); force=true)
    rm(joinpath(app_libdir, "julia", backup_default_sysimage_name()); force=true)
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
