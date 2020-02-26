module PackageCompiler

using Base: active_project
using Libdl: Libdl
using Pkg: Pkg
using UUIDs: UUID, uuid1

export create_sysimage, create_app, audit_app, restore_default_sysimage

include("juliaconfig.jl")

const NATIVE_CPU_TARGET = "native"
# See https://github.com/JuliaCI/julia-buildbot/blob/489ad6dee5f1e8f2ad341397dc15bb4fce436b26/master/inventory.py
function default_app_cpu_target()
    if Sys.ARCH === :i686
        return "pentium4;sandybridge,-xsaveopt,clone_all"
    elseif Sys.ARCH === :x86_64
        return "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
    elseif Sys.ARCH === :arm
        return "armv7-a;armv7-a,neon;armv7-a,neon,vfp4"
    elseif Sys.ARCH === :aarch64
        return "generic" # is this really the best here?
    elseif Sys.ARCH === :powerpc64le
        return "pwr8"
    else
        return "generic"
    end
end

current_process_sysimage_path() = unsafe_string(Base.JLOptions().image_file)

all_stdlibs() = readdir(Sys.STDLIB)

yesno(b::Bool) = b ? "yes" : "no"

function load_all_deps(ctx)
    if isdefined(Pkg.Operations, :load_all_deps!)
        pkgs = Pkg.Types.PackageSpec[]
        Pkg.Operations.load_all_deps!(ctx, pkgs)
    else
        pkgs = Pkg.Operations.load_all_deps(ctx)
    end
    return pkgs
end

function bitflag()
    if Sys.ARCH == :i686
        return `-m32`
    elseif Sys.ARCH == :x86_64
        return `-m64`
    else
        return ``
    end
end

function march()
    if Sys.ARCH === :i686
        return "-march=pentium4"
    elseif Sys.ARCH === :x86_64
        return "-march=x86-64"
    elseif Sys.ARCH === :arm
        return "-march=armv7-a+simd"
    elseif Sys.ARCH === :aarch64
        return "-march=armv8-a+crypto+simd"
    elseif Sys.ARCH === :powerpc64le
        return nothing
    else
        return nothing
    end
end

# Overwriting an open file is problematic in Windows
# so move it out of the way first
function move_default_sysimage_if_windows()
    if Sys.iswindows() && isfile(default_sysimg_path())
        mv(default_sysimg_path(), tempname())
    end
end

function run_with_env(cmd, compiler)
    if Sys.iswindows()
        env = copy(ENV)
        env["PATH"] = string(env["PATH"], ";", dirname(compiler))
        run(Cmd(cmd; env=env))
    else
        run(cmd)
    end
end

function get_compiler()
    cc = get(ENV, "JULIA_CC", nothing)
    if cc !== nothing
        return cc
    end
    if Sys.iswindows()
        return joinpath(Pkg.Artifacts.artifact"x86_64-w64-mingw32", "mingw64", "bin", "gcc.exe")
    end
    if Sys.which("gcc") !== nothing
        return "gcc"
    elseif Sys.which("clang") !== nothing
        return "clang"
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
    content = replace(sysimg_content,
        r"stdlibs = \[(.*?)\]"s => string("stdlibs = [", join(":" .* stdlibs, ",\n"), "]"))
    # Also replace a maximum call which fails for empty collections,
    # see https://github.com/JuliaLang/julia/pull/34727
    content = replace(content, "maximum(textwidth.(string.(stdlibs)))" =>
                               "reduce(max, textwidth.(string.(stdlibs)); init=0)")
    return content
end

function create_fresh_base_sysimage(stdlibs::Vector{String}; cpu_target::String)
    tmp = mktempdir()
    sysimg_source_path = Base.find_source_file("sysimg.jl")
    base_dir = dirname(sysimg_source_path)
    tmp_corecompiler_ji = joinpath(tmp, "corecompiler.ji")
    tmp_sys_ji = joinpath(tmp, "sys.ji")
    compiler_source_path = joinpath(base_dir, "compiler", "compiler.jl")

    @info "PackageCompiler: creating base system image (incremental=false)..."
    cd(base_dir) do
        # Create corecompiler.ji
        cmd = `$(get_julia_cmd()) --cpu-target $cpu_target --output-ji $tmp_corecompiler_ji
                                  -g0 -O0 $compiler_source_path`
        @debug "running $cmd"
        read(cmd)

        # Use that to create sys.ji
        new_sysimage_content = rewrite_sysimg_jl_only_needed_stdlibs(stdlibs)
        new_sysimage_source_path = joinpath(base_dir, "sysimage_packagecompiler_$(uuid1()).jl")
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

function run_precompilation_script(project::String, sysimg::String, precompile_file::Union{String, Nothing})
    tracefile = tempname()
    if precompile_file == nothing
        arg = `-e ''`
    else
        arg = `$precompile_file`
    end
    touch(tracefile)
    cmd = `$(get_julia_cmd()) --sysimage=$(sysimg) --project=$project
            --compile=all --trace-compile=$tracefile $arg`
    @debug "run_precompilation_script: running $cmd"
    run(cmd)
    return tracefile
end

# Load packages in a normal julia process to make them precompile "normally"
function do_ensurecompiled(project, packages, sysimage)
    use = join("using " .* packages, '\n')
    cmd = `$(get_julia_cmd()) --sysimage=$sysimage --project=$project -e $use`
    @debug "running $cmd"
    read(cmd, String)
    return nothing
end

function create_sysimg_object_file(object_file::String, packages::Vector{String};
                            project::String,
                            base_sysimage::String,
                            precompile_execution_file::Vector{String},
                            precompile_statements_file::Vector{String},
                            cpu_target::String,
                            script::Union{Nothing, String},
                            isapp::Bool)

    # Handle precompilation
    precompile_statements = ""
    @debug "running precompilation execution script..."
    tracefiles = String[]
    for file in (isempty(precompile_execution_file) ? (nothing,) : precompile_execution_file)
        tracefile = run_precompilation_script(project, base_sysimage, file)
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
                    @debug "failed to execute \$statement"
                end
            end
        end # module
        """

    # include all packages into the sysimg
    julia_code = """
        Base.reinit_stdio()
        @eval Sys BINDIR = ccall(:jl_get_julia_bindir, Any, ())::String
        Base.init_load_path()
        Base.init_depot_path()
        """

    # Ensure packages to be put into sysimage are precompiled by loading them in a
    # separate process first.
    if !isempty(packages)
        do_ensurecompiled(project, packages, base_sysimage)
    end

    for pkg in packages
        julia_code *= """
            using $pkg
            """
    end

    julia_code *= precompile_code

    if script !== nothing
        julia_code *= """
        include($(repr(abspath(script))))
        """
    end

    if isapp
        # If it is an app, there is only one packages
        @assert length(packages) == 1
        packages[1]
        app_start_code = """
        Base.@ccallable function julia_main()::Cint
            try
                $(packages[1]).julia_main()
            catch
                Core.print("julia_main() threw an unhandled exception")
                return 1
            end
        end
        """
        julia_code *= app_start_code
    end

    julia_code *= """
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        """

    # finally, make julia output the resulting object file
    @debug "creating object file at $object_file"
    @info "PackageCompiler: creating system image object file, this might take a while..."

    cmd = `$(get_julia_cmd()) --cpu-target=$cpu_target
                              --sysimage=$base_sysimage --project=$project --output-o=$(object_file) -e $julia_code`
    @debug "running $cmd"
    run(cmd)
end

default_sysimg_path() = abspath(Sys.BINDIR, "..", "lib", "julia", "sys." * Libdl.dlext)
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

function check_packages_in_project(ctx, packages)
    packages_in_project = collect(keys(ctx.env.project.deps))
    if ctx.env.pkg !== nothing
        push!(packages_in_project, ctx.env.pkg.name)
    end
    packages_not_in_project = setdiff(string.(packages), packages_in_project)
    if !isempty(packages_not_in_project)
        error("package(s) $(join(packages_not_in_project, ", ")) not in project")
    end
end

"""
    create_sysimage(packages::Union{Symbol, Vector{Symbol}}; kwargs...)

Create a system image that includes the package(s) in `packages`.  An attempt
to automatically find a compiler will be done but can also be given explicitly
by setting the environment variable `JULIA_CC` to a path to a compiler

### Keyword arguments:

- `sysimage_path::Union{String,Nothing}`: The path to where
   the resulting sysimage should be saved. If set to `nothing` the keyword argument
   `replace_defalt` needs to be set to `true`.

- `project::String`: The project that should be active when the sysimage is created,
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

### Advanced keyword arguments

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image.

- `script::String`: Path to a file that gets executed in the `--output-o` process.
"""
function create_sysimage(packages::Union{Symbol, Vector{Symbol}}=Symbol[];
                         sysimage_path::Union{String,Nothing}=nothing,
                         project::String=dirname(active_project()),
                         precompile_execution_file::Union{String, Vector{String}}=String[],
                         precompile_statements_file::Union{String, Vector{String}}=String[],
                         incremental::Bool=true,
                         filter_stdlibs=false,
                         replace_default::Bool=false,
                         cpu_target::String=NATIVE_CPU_TARGET,
                         script::Union{Nothing, String}=nothing,
                         base_sysimage::Union{Nothing, String}=nothing,
                         isapp::Bool=false)
    precompile_statements_file = abspath.(precompile_statements_file)
    precompile_execution_file = abspath.(precompile_execution_file)
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
    packages = string.(vcat(packages)) # Package names are often used as string inside Julia
    precompile_execution_file  = vcat(precompile_execution_file)
    precompile_statements_file = vcat(precompile_statements_file)

    # Instantiate the project
    ctx = create_pkg_context(project)
    @debug "instantiating project at $(repr(project))"
    Pkg.instantiate(ctx)

    check_packages_in_project(ctx, packages)

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

    # Create the sysimage
    object_file = tempname() * ".o"
    create_sysimg_object_file(object_file, packages;
                              project=project,
                              base_sysimage=base_sysimage,
                              precompile_execution_file=precompile_execution_file,
                              precompile_statements_file=precompile_statements_file,
                              cpu_target=cpu_target,
                              script=script,
                              isapp=isapp)
    create_sysimg_from_object_file(object_file, sysimage_path)

    # Maybe replace default sysimage
    if replace_default
        if !isfile(backup_default_sysimg_path())
            @debug "making a backup of default sysimg"
            cp(default_sysimg_path(), backup_default_sysimg_path())
        end
        move_default_sysimage_if_windows()
        mv(sysimage_path, default_sysimg_path(); force=true)
        @info "PackageCompiler: default sysimg replaced, restart Julia for the new sysimg to be in effect"
    end
    rm(object_file; force=true)
    return nothing
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
    compiler = get_compiler()
    m = something(march(), ``)
    cmd = `$compiler $(bitflag()) $m -shared -L$(julia_libdir) -o $sysimage_path $o_file -ljulia $extra`
    @debug "running $cmd"
    run_with_env(cmd, compiler)
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
    move_default_sysimage_if_windows()
    mv(backup_default_sysimg_path(), default_sysimg_path(); force=true)
    @info "PackageCompiler: default sysimg restored, restart Julia for the new sysimg to be in effect"
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
    pkgs = load_all_deps(ctx)
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
    create_app(app_source::String, compiled_app::String; kwargs...)

Compile an app with the source in `app_source` to the folder `compiled_app`.
The folder `app_source` needs to contain a package where the package include a
function with the signature

```
julia_main()::Cint
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

### Advanced keyword arguments

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image.
"""
function create_app(package_dir::String,
                    app_dir::String;
                    precompile_execution_file::Union{String, Vector{String}}=String[],
                    precompile_statements_file::Union{String, Vector{String}}=String[],
                    incremental=false,
                    filter_stdlibs=false,
                    audit=true,
                    force=false,
                    cpu_target::String=default_app_cpu_target())
    precompile_statements_file = abspath.(precompile_statements_file)
    precompile_execution_file = abspath.(precompile_execution_file)
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
                  " remove the directory)")
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
                            cpu_target=cpu_target)

            create_sysimage(Symbol(app_name); sysimage_path=sysimg_file, project=package_dir,
                            incremental=true,
                            precompile_execution_file=precompile_execution_file,
                            precompile_statements_file=precompile_statements_file,
                            cpu_target=cpu_target,
                            base_sysimage=tmp_base_sysimage,
                            isapp=true)
        else
            create_sysimage(Symbol(app_name); sysimage_path=sysimg_file, project=package_dir,
                                              incremental=incremental, filter_stdlibs=filter_stdlibs,
                                              precompile_execution_file=precompile_execution_file,
                                              precompile_statements_file=precompile_statements_file,
                                              cpu_target=cpu_target,
                                              isapp=true)
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
    compiler = get_compiler()
    m = something(march(), ``)
    cmd = `$compiler -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) $(bitflag()) $m -o $(executable_path) $(wrapper) $(sysimage_path) -O2 $rpath $flags`
    @debug "running $cmd"
    run_with_env(cmd, compiler)
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

    pkgs = load_all_deps(ctx)

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
