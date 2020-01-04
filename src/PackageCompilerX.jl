module PackageCompilerX

using Base: active_project
using Libdl: Libdl
using Pkg: Pkg
using UUIDs: UUID

export create_sysimage, create_app, audit_app, restore_default_sysimage

include("juliaconfig.jl")

const NATIVE_CPU_TARGET = "native"
const APP_CPU_TARGET = "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"

current_process_sysimage_path() = unsafe_string(Base.JLOptions().image_file)

all_stdlibs() = readdir(Sys.STDLIB)

yesno(b::Bool) = b ? "yes" : "no"

function get_compiler()
    cc = get(ENV, "JULIA_CC", nothing)
    if cc !== nothing
        return `$cc`
    end
    if Sys.which("gcc") !== nothing
        return `gcc`
    elseif Sys.which("clang") !== nothing
        return `clang`
    end
    if Sys.iswindows()
        if Sys.which("x86_64-w64-mingw32-gcc") !== nothing
            return `x86_64-w64-mingw32-gcc`
        end
    end
    error("could not find a compiler, looked for `gcc` and `clang`")
end

function get_julia_cmd()
    julia_path = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia_path --color=yes --startup-file=no`
end

function rewrite_sysimg_jl_only_needed_stdlibs(stdlibs::Vector{String})
    sysimg_source_path = Base.find_source_file("sysimg.jl")
    sysimg_content = read(sysimg_source_path, String)
    # replaces the hardcoded list of stdlibs in sysimg.jl with
    # the stdlibs that is given as argument
    return replace(sysimg_content, r"stdlibs = \[(.*?)\]"s => string("stdlibs = [", join(":" .* string.(stdlibs), ",\n"), "]"))
end

function create_fresh_base_sysimage(stdlibs::Vector{String}; cpu_target::String)
    tmp = mktempdir(cleanup=false)
    sysimg_source_path = Base.find_source_file("sysimg.jl")
    base_dir = dirname(sysimg_source_path)
    tmp_corecompiler_ji = joinpath(tmp, "corecompiler.ji")
    tmp_sys_ji = joinpath(tmp, "sys.ji")
    compiler_source_path = joinpath(base_dir, "compiler", "compiler.jl")

    @info "PackageCompilerX: creating base system image (incremental=false)..."
    cd(base_dir) do
        # Create corecompiler.ji
        cmd = `$(get_julia_cmd()) --cpu-target $cpu_target --output-ji $tmp_corecompiler_ji
                                  -g0 -O0 $compiler_source_path`
        @debug "running $cmd"
        read(cmd)

        # Use that to create sys.ji
        new_sysimage_content = rewrite_sysimg_jl_only_needed_stdlibs(stdlibs)
        new_sysimage_source_path = joinpath(base_dir, "sysimage_packagecompiler_x.jl")
        write(new_sysimage_source_path, new_sysimage_content)
        try
            cmd = `$(get_julia_cmd()) --cpu-target $cpu_target
                                      --sysimage=$tmp_corecompiler_ji
                                      -g1 -O0 --output-ji=$tmp_sys_ji $new_sysimage_source_path`
            @debug "running $cmd"
            read(cmd)
        finally
            rm(new_sysimage_source_path; force=true)
        end
    end

    return tmp_sys_ji
end

function run_precompilation_script(project::String, precompile_file::Union{String, Nothing})
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
    read(cmd)
    return tracefile
end

function create_sysimg_object_file(object_file::String, packages::Vector{Symbol};
                            project::String,
                            base_sysimage::String,
                            precompile_execution_file::Vector{String},
                            precompile_statements_file::Vector{String},
                            cpu_target::String,
                            compiled_modules::Bool)
    # include all packages into the sysimg
    julia_code = """
        Base.reinit_stdio()
        Base.init_load_path()
        Base.init_depot_path()
        """
    for package in packages
        julia_code *= "using $package\n"
    end
    
    # handle precompilation
    precompile_statements = ""
    @debug "running precompilation execution script..."
    tracefiles = String[]
    for file in (isempty(precompile_execution_file) ? (nothing,) : precompile_execution_file)
        tracefile = run_precompilation_script(project, file)
        precompile_statements *= "    append!(precompile_statements, readlines($(repr(tracefile))))\n"
    end
    for file in precompile_statements_file
        precompile_statements *=
            "    append!(precompile_statements, readlines($(repr(file))))\n"
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

    julia_code *= """
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
    """

    # finally, make julia output the resulting object file
    @debug "creating object file at $object_file"
    @info "PackageCompilerX: creating system image object file, this might take a while..."

    cmd = `$(get_julia_cmd()) --compiled-modules=$(yesno(compiled_modules)) --cpu-target=$cpu_target
                              --sysimage=$base_sysimage --project=$project --output-o=$(object_file) -e $julia_code`
    @debug "running $cmd"
    run(cmd)
end

default_sysimg_path() = joinpath(julia_private_libdir(), "sys." * Libdl.dlext)
default_sysimg_name() = basename(default_sysimg_path())
backup_default_sysimg_path() = default_sysimg_path() * ".backup"
backup_default_sysimg_name() = basename(backup_default_sysimg_path())

# TODO: Also check UUIDs for stdlibs, not only names
gather_stdlibs_project(project::String) = gather_stdlibs_project(create_pkg_context(project))
function gather_stdlibs_project(ctx)
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
    create_sysimage(packages::Union{Symbol, Vector{Symbol}}; kwargs...)

Create a system image that includes the package(s) in `packages`.  An attempt
to automatically find a compiler will be done but can also be given explicitly
by setting the envirnment variable `JULIA_CC` to a path to a compiler

### Keyword arguments:

- `sysimage_path::Union{String,Nothing}`: The path to where
   the resulting sysimage should be saved. If set to `nothing` the keyword argument
   `replace_defalt` needs to be set to `true`.

- `project::String`: The project that should be active when the sysmage is created,
   defaults to the current active project.

- `precompile_execution_file::Union{String, Vector{String}}`: A file or list of 
   files that contain code which precompilation statements should be recorded from.

- `precompile_statements_file::Union{String, Vector{String}}`: A file or list of
   files that contains precompilation statements that should be included in the sysimage.

- `incremental::Bool`: If `true`, build the new sysimage on top of the sysimage
   of the current process otherwise build a new sysimage from scratch. Defaults to `true`.

- `filter_stdlibs::Bool`: If `true`, only include stdlibs that are in the project file.
   Defaults to `false`, only set to `true` if you know the potential pitfalls.

- `replace_default::Bool`: If `true`, replaces the default system image which is automatically
   used when Julia starts. To replace with the one Julia ships with, use [`restore_default_sysimage()`](@ref)
"""
function create_sysimage(packages::Union{Symbol, Vector{Symbol}};
                         sysimage_path::Union{String,Nothing}=nothing,
                         project::String=dirname(active_project()),
                         precompile_execution_file::Union{String, Vector{String}}=String[],
                         precompile_statements_file::Union{String, Vector{String}}=String[],
                         incremental::Bool=true,
                         filter_stdlibs=false,
                         replace_default::Bool=false,
                         cpu_target::String=NATIVE_CPU_TARGET,
                         base_sysimage::Union{Nothing, String}=nothing,
                         compiled_modules=true)
    if replace_default==true
        if sysimage_path !== nothing
            error("cannot specify `sysimage_path` when `replace_default` is `true`")
        end
    end
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

    # Functions lower down handles `packages` and precompilation file as arrays so convert here
    packages = vcat(packages)
    precompile_execution_file  = vcat(precompile_execution_file)
    precompile_statements_file = vcat(precompile_statements_file)

    # Instantiate the project
    ctx = create_pkg_context(project)
    @debug "instantiating project at $(repr(project))"
    Pkg.instantiate(ctx)

    if !incremental
        if base_sysimage !== nothing
            error("cannot specify `base_sysimage`  when `incremental=false`")
        end
        if filter_stdlibs
            stdlibs = gather_stdlibs_project(ctx)
        else
            stdlibs= all_stdlibs()
        end
        base_sysimage = create_fresh_base_sysimage(stdlibs; cpu_target=cpu_target)
    else
        if base_sysimage == nothing
            base_sysimage = current_process_sysimage_path()
        end
    end

    object_file = tempname() * ".o"
    create_sysimg_object_file(object_file, packages;
                              project=project,
                              base_sysimage=base_sysimage,
                              precompile_execution_file=precompile_execution_file,
                              precompile_statements_file=precompile_statements_file,
                              cpu_target=cpu_target,
                              compiled_modules=compiled_modules)
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
    cmd = `$(get_compiler()) -shared -L$(julia_libdir) -o $sysimage_path $o_file -ljulia $extra`
    @debug "running $cmd"
    run(cmd)
    return nothing
end

"""
    restore_default_sysimage()

Restores the default system image to the one that Julia shipped with.
Useful after running [`create_sysimage`](@ref) with `replace_default=true`.
"""
function restore_default_sysimage()
    if !isfile(backup_default_sysimg_path())
        error("did not find a backup sysimg")
    end
    cp(backup_default_sysimg_path(), default_sysimg_path(); force=true)
    rm(backup_default_sysimg_path())
    @info "PackageCompilerX: default sysimg restored, restart Julia for the new sysimg to be in effect"
    return nothing
end

const REQUIRES = "Requires" => UUID("ae029012-a4dd-5104-9daa-d747884805df")

function create_pkg_context(project)
    project_toml_path = Pkg.Types.projectfile_path(project; strict=true)
    if project_toml_path === nothing
        error("could not find project at $(repr(project))")
    end
    return Pkg.Types.Context(env=Pkg.Types.EnvCache(project_toml_path))
end

"""
    audit_app(app_dir::String)

Check for possible problems with regards to relocatability for
the project at `app_dir`.

!!! warning
    This cannot guarantee that the project is free of relocatability problems,
    it can only detect some known bad cases and warn about those.
"""
audit_app(app_dir::String) = audit_app(create_pkg_context(app_dir))
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
    create_app(app_source::String, compiled_app::String)

Compile an app with the source in `app_source` to the folder `compiled_app`.
The folder `app_source` needs to contain a package where the package include a
function with the signature

```
Base.@ccallable julia_main()::Cint
    # Perhaps do something based on ARGS
    ...
end
```

The executable will be placed in a folder called `bin` in `compiled_app` and
when the executabl run the `julia_main` function is called.

An attempt to automatically find a compiler will be done but can also be given
explicitly by setting the envirnment variable `JULIA_CC` to a path to a
compiler.

### Keyword arguments:

- `precompile_execution_file::Union{String, Vector{String}}`: A file or list of
   files that contain code which precompilation statements should be recorded from.

- `precompile_statements_file::Union{String, Vector{String}}`: A file or list of
   files that contains precompilation statements that should be included in the sysimage
   for the app.

- `incremental::Bool`: If `true`, build the new sysimage on top of the sysimage
   of the current process otherwise build a new sysimage from scratch. Defaults to `false`.

- `filter_stdlibs::Bool`: If `true`, only include stdlibs that are in the project file.
   Defaults to `false`, only set to `true` if you know the potential pitfalls.

- `audit::Bool`: Warn about eventual relocatability problems with the app, defaults
   to `true`.

- `force::Bool`: Remove the folder `compiled_app` if it exists before creating the app.
"""
function create_app(package_dir::String,
                    app_dir::String;
                    precompile_execution_file::Union{String, Vector{String}}=String[],
                    precompile_statements_file::Union{String, Vector{String}}=String[],
                    incremental=false,
                    filter_stdlibs=false,
                    audit=true,
                    force=false)
    package_dir = abspath(package_dir)
    ctx = create_pkg_context(package_dir)
    if isempty(ctx.env.manifest)
        @warn "it is not recommended to create an app without a preexisting manifest"
    end
    if ctx.env.pkg === nothing
        error("expected package to have a `name`-entry")
    end
    app_name = ctx.env.pkg.name
    sysimg_file = app_name * "." * Libdl.dlext
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
        if !incremental
            tmp = mktempdir()
            # Use workaround at https://github.com/JuliaLang/julia/issues/34064#issuecomment-563950633
            # by first creating a normal "empty" sysimage and then use that to finally create the one
            # with the @ccallable function
            tmp_base_sysimage = joinpath(tmp, "tmp_sys.so")
            create_sysimage(Symbol[]; sysimage_path=tmp_base_sysimage, project=package_dir,
                            incremental=false, filter_stdlibs=filter_stdlibs,
                            cpu_target=APP_CPU_TARGET)

            create_sysimage(Symbol(app_name); sysimage_path=sysimg_file, project=package_dir,
                            incremental=true,
                            precompile_execution_file=precompile_execution_file,
                            precompile_statements_file=precompile_statements_file,
                            cpu_target=APP_CPU_TARGET,
                            base_sysimage=tmp_base_sysimage,
                            compiled_modules=false #= workaround julia#34076=#)
        else
            create_sysimage(Symbol(app_name); sysimage_path=sysimg_file, project=package_dir,
                                              incremental=incremental, filter_stdlibs=filter_stdlibs,
                                              precompile_execution_file=precompile_execution_file,
                                              precompile_statements_file=precompile_statements_file,
                                              cpu_target=APP_CPU_TARGET,
                                              compiled_modules=false #= workaround julia#34076=#)
        end
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
    @assert ctx.env.pkg !== nothing
    # This is kinda ugly...
    ctx.env.pkg.path = dirname(ctx.env.project_file)
    push!(pkgs, ctx.env.pkg)

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
                    meta = Pkg.Artifacts.artifact_meta(name, artifacts_toml_path)
                    meta == nothing && continue
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
