module PackageCompiler

using Base: active_project
using Libdl: Libdl
using Pkg: Pkg
using UUIDs: UUID, uuid1

export create_sysimage, create_app, create_library, audit_app, restore_default_sysimage

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
@static if VERSION >= v"1.6.0-DEV.1673"
    sysimage_modules() = map(x->x.name, Base._sysimage_modules)
else
    sysimage_modules() = all_stdlibs()
end
stdlibs_in_sysimage() = intersect(all_stdlibs(), sysimage_modules())
stdlibs_not_in_sysimage() = setdiff(all_stdlibs(), sysimage_modules())


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
function source_path(ctx, pkg)
    if VERSION <= v"1.4.0-rc1"
        Pkg.Operations.source_path(pkg)
    else
        Pkg.Operations.source_path(ctx, pkg)
    end
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
    @static if Sys.iswindows()
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

function get_compat_version(version::VersionNumber, level::String)
    level == "full" ? version :
    level == "patch" ? VersionNumber(version.major, version.minor, version.patch) :
    level == "minor" ? VersionNumber(version.major, version.minor) :
    level == "major" ? VersionNumber(version.major) :
    error("Unknown level: $level")
end

function get_compat_version_str(version::VersionNumber, level::String)
    level == "full" ? "$(version)" :
    level == "patch" ? "$(version.major).$(version.minor).$(version.patch)" :
    level == "minor" ? "$(version.major).$(version.minor)" :
    level == "major" ? "$(version.major)" :
    error("Unknown level: $level")
end

function get_sysimg_file(name::String;
                     library_only::Bool=false,
                     version::Union{VersionNumber, Nothing}=nothing,
                     level::String="patch")

    dlext = Libdl.dlext
    (!library_only || Sys.iswindows()) && return "$name.$dlext"

    # For libraries on Unix/Apple, make sure the name starts with "lib"

    if !startswith(name, "lib")
        name = "lib" * name
    end

    if version === nothing
        return "$name.$dlext"
    end

    version = get_compat_version_str(version, level)
    sysimg_file = (
        Sys.isapple() ? "$name.$version.$dlext" :  # libname.1.2.3.dylib
        Sys.isunix() ? "$name.$dlext.$version" :   # libname.so.1.2.3
        error("Unable to determine sysimage_file; system is not Windows, Apple, or UNIX!")
    )

    return sysimg_file
end

function get_depot_path(root_dir::String, library_only::Bool)
    # Use <root>/share/julia as the depot path when creating libraries
    library_only && return joinpath(root_dir, "share", "julia")
    return root_dir
end

function get_soname(name::String;
                library_only::Bool=false,
                version::Union{VersionNumber, Nothing}=nothing,
                compat_level::String="major")

    (!Sys.isunix() || Sys.isapple()) && return nothing
    return get_sysimg_file(name, library_only=library_only, version=version, level=compat_level)
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
        new_sysimage_content *= "\nempty!(Base.atexit_hooks)\n"
        new_sysimage_source_path = joinpath(tmp, "sysimage_packagecompiler_$(uuid1()).jl")
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
    read(cmd)
    return tracefile
end

# Load packages in a normal julia process to make them precompile "normally"
function do_ensurecompiled(project, packages, sysimage)
    use = join("import " .* packages, '\n')
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
    precompile_files = String[]
    @debug "running precompilation execution script..."
    tracefiles = String[]
    for file in (isempty(precompile_execution_file) ? (nothing,) : precompile_execution_file)
        tracefile = run_precompilation_script(project, base_sysimage, file)
        push!(precompile_files, tracefile)
    end
    append!(precompile_files, precompile_statements_file)

    precompile_code = """
        # This @eval prevents symbols from being put into Main
        @eval Module() begin
            PrecompileStagingArea = Module()
            for (_pkgid, _mod) in Base.loaded_modules
                if !(_pkgid.name in ("Main", "Core", "Base"))
                    eval(PrecompileStagingArea, :(const \$(Symbol(_mod)) = \$_mod))
                end
            end
            precompile_files = String[
                $(join(map(repr, precompile_files), "\n" * " " ^ 8))
            ]
            for file in precompile_files, statement in eachline(file)
                # println(statement)
                # The compiler has problem caching signatures with `Vararg{?, N}`. Replacing
                # N with a large number seems to work around it.
                statement = replace(statement, r"Vararg{(.*?), N} where N" => s"Vararg{\\1, 100}")
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
        @eval Sys STDLIB = $(repr(abspath(Sys.BINDIR, "../share/julia/stdlib", string('v', VERSION.major, '.', VERSION.minor))))
        Base.init_load_path()
        if isdefined(Base, :init_active_project)
            Base.init_active_project()
        end
        Base.init_depot_path()
        """

    # Ensure packages to be put into sysimage are precompiled by loading them in a
    # separate process first.
    if !isempty(packages)
        do_ensurecompiled(project, packages, base_sysimage)
    end

    for pkg in packages
        julia_code *= """
            import $pkg
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
    sysimage_stdlibs = stdlibs_in_sysimage()
    non_sysimage_stdlibs = stdlibs_not_in_sysimage()
    sysimage_stdlibs_project = String[]
    non_sysimage_stdlibs_project = String[]
    for (uuid, pkg) in ctx.env.manifest
        if pkg.name in sysimage_stdlibs
            push!(sysimage_stdlibs_project, pkg.name)
        elseif pkg.name in non_sysimage_stdlibs
            push!(non_sysimage_stdlibs_project, pkg.name)
        end
    end
    return sysimage_stdlibs_project, non_sysimage_stdlibs_project
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
   `replace_default` needs to be set to `true`.

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

- `julia_init_c_file::String`: File to include in the system image with functions for
   initializing julia from external code.  Used when creating a shared library.

- `version::VersionNumber`: Shared library version number (optional).  Added to the sysimg
   `.so` name on Linux/UNIX, and the `.dylib` name on Apple platforms, and to set the internal
   `current_version` on Apple.  Ignored on Windows.

- `compat_level::String`: compatibility level for library.  One of "major", "minor".
   With `version`, used to determine the `compatibility_version` on Apple.

- `soname`: On linux, used to set the internal soname for the system image.

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
                         base_sysimage::Union{Nothing, String}=nothing,
                         isapp::Bool=false,
                         julia_init_c_file=nothing,
                         version=nothing,
                         compat_level::String="major",
                         soname=nothing,
                         cpu_target::String=NATIVE_CPU_TARGET,
                         script::Union{Nothing, String}=nothing)

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
    Pkg.instantiate(ctx, verbose=true)

    check_packages_in_project(ctx, packages)

    if !incremental
        if base_sysimage !== nothing
            error("cannot specify `base_sysimage`  when `incremental=false`")
        end
        if filter_stdlibs
            sysimage_stdlibs, non_sysimage_stdlibs = gather_stdlibs_project(ctx)
        else
            sysimage_stdlibs = stdlibs_in_sysimage()
            non_sysimage_stdlibs = stdlibs_not_in_sysimage()
        end
        base_sysimage = create_fresh_base_sysimage(sysimage_stdlibs; cpu_target=cpu_target)
    else
        if base_sysimage === nothing
            base_sysimage = current_process_sysimage_path()
        end
    end

    o_init_file = julia_init_c_file === nothing ? nothing : compile_c_init_julia(julia_init_c_file, sysimage_path)

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
    create_sysimg_from_object_file(object_file,
                                   sysimage_path,
                                   o_init_file=o_init_file,
                                   compat_level=compat_level,
                                   version=version,
                                   soname=soname)

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

function compile_c_init_julia(julia_init_c_file::String, sysimage_path::String)
    @debug "Compiling $julia_init_c_file"
    compiler = get_compiler()
    m = something(march(), ``)
    flags = Base.shell_split(cflags())

    o_init_file = splitext(julia_init_c_file)[1] * ".o"
    cmd = `$compiler -c -O2 -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) $(bitflag()) $flags $m -o $o_init_file $julia_init_c_file`

    @debug "running $cmd"
    run_with_env(cmd, compiler)
    return o_init_file
end

function get_extra_linker_flags(version, compat_level, soname)
    current_ver_arg = ``
    compat_ver_arg = ``

    if version !== nothing
        compat_version = get_compat_version(version, compat_level)
        current_ver_arg = `-current_version $version`
        compat_ver_arg = `-compatibility_version $compat_version`
    end

    soname_arg = soname === nothing ? `` : `-Wl,-soname,$soname`
    rpath_args = rpath()

    extra = (
        Sys.iswindows() ? `-Wl,--export-all-symbols` :
        Sys.isapple() ? `-fPIC $compat_ver_arg $current_ver_arg $rpath_args` :
        Sys.isunix() ? `-fPIC $soname_arg $rpath_args` :
        error("What kind of machine is this?")
    )

    return extra
end

function create_sysimg_from_object_file(input_object::String,
                                        sysimage_path::String;
                                        o_init_file=nothing,
                                        version=nothing,
                                        compat_level::String="major",
                                        soname=nothing)

    julia_libdir = dirname(Libdl.dlpath("libjulia"))

    o_files = [input_object]
    o_init_file !== nothing && push!(o_files, o_init_file)

    # Prevent compiler from stripping all symbols from the shared lib.
    # TODO: On clang on windows this is called something else
    if Sys.isapple()
        o_file_flags = `-Wl,-all_load $o_files`
    else
        o_file_flags = `-Wl,--whole-archive $o_files -Wl,--no-whole-archive`
    end

    extra = get_extra_linker_flags(version, compat_level, soname)

    compiler = get_compiler()
    m = something(march(), ``)
    cmd = if VERSION >= v"1.6.0-DEV.1673"
        private_libdir = if Base.DARWIN_FRAMEWORK # taken from Libdl tests
            if ccall(:jl_is_debugbuild, Cint, ()) != 0
                dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME * "_debug")))
            else
                joinpath(dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME))),"Frameworks")
            end
        elseif ccall(:jl_is_debugbuild, Cint, ()) != 0
            dirname(abspath(Libdl.dlpath("libjulia-internal-debug")))
        else
            dirname(abspath(Libdl.dlpath("libjulia-internal")))
        end
        `$compiler $(bitflag()) $m -shared -L$(julia_libdir) -L$(private_libdir) -o $sysimage_path $o_file_flags -ljulia-internal -ljulia $extra`
    else
        `$compiler $(bitflag()) $m -shared -L$(julia_libdir) -o $sysimage_path $o_file_flags -ljulia $extra`
    end
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
        pkg_source = source_path(ctx, pkg)
        pkg_source === nothing && continue
        if isfile(joinpath(pkg_source, "deps", "build.jl"))
            @warn "Package $(pkg.name) has a build script, this might indicate that it is not relocatable"
        end
    end
    return
end

"""
    create_app(package_dir::String, compiled_app::String; kwargs...)

Compile an app with the source in `package_dir` to the folder `compiled_app`.
The folder `package_dir` needs to contain a package where the package includes a
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

- `app_name::String`: an alternative name for the compiled app.  If not provided,
   the name of the package (as specified in Project.toml) is used.

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
                    app_name=nothing,
                    precompile_execution_file::Union{String, Vector{String}}=String[],
                    precompile_statements_file::Union{String, Vector{String}}=String[],
                    incremental=false,
                    filter_stdlibs=false,
                    audit=true,
                    force=false,
                    c_driver_program::String=joinpath(@__DIR__, "embedding_wrapper.c"),
                    cpu_target::String=default_app_cpu_target())

    _create_app(package_dir, app_dir, app_name, precompile_execution_file,
        precompile_statements_file, incremental, filter_stdlibs, audit, force, cpu_target,
        c_driver_program=c_driver_program)
end

"""
    create_library(package_dir::String, dest_dir::String; kwargs...)

Compile an library with the source in `package_dir` to the folder `dest_dir`.
The folder `package_dir` should to contain a package with C-callable functions,
e.g.

```
Base.@ccallable function julia_cg(fptr::Ptr{Cvoid}, cx::Ptr{Cdouble}, cb::Ptr{Cdouble}, len::Csize_t)::Cint
    try
        x = unsafe_wrap(Array, cx, (len,))
        b = unsafe_wrap(Array, cb, (len,))
        A = COp(fptr,len)
        cg!(x, A, b)
    catch
        Base.invokelatest(Base.display_error, Base.catch_stack())
        return 1
    end
    return 0
end
```

The library will be placed in the `lib` folder in `dest_dir` (or `bin` on Windows),
and can be linked to and called into from C/C++ or other languages that can use C libraries.

Note that any applications/programs linking to this library may need help finding
it at run time.  Options include

* Installing all libraries somewhere in the library search path.
* Adding `/path/to/libname` to an appropriate library search path environment
  variable (`DYLD_LIBRARY_PATH` on OSX, `PATH` on Windows, or `LD_LIBRARY_PATH`
  on Linux/BSD/Unix).
* Running `install_name_tool -change libname /path/to/libname` (OSX)

To use any Julia exported functions, you *must* first call `init_julia(argc, argv)`,
where `argc` and `argv` are parameters that would normally be passed to `julia` on the
command line (e.g., to set up the number of threads or processes).

When your program is exiting, it is also suggested to call `shutdown_julia(retcode)`,
to allow Julia to cleanly clean up resources and call any finalizers.  (This function
simply calls `jl_atexit_hook(retcode)`.)

An attempt to automatically find a compiler will be done but can also be given
explicitly by setting the envirnment variable `JULIA_CC` to a path to a
compiler.

### Keyword arguments:

- `lib_name::String`: an alternative name for the compiled library.  If not provided,
   the name of the package (as specified in Project.toml) is used.  `lib` will be
   prepended to the name if it is not already present.

- `precompile_execution_file::Union{String, Vector{String}}`: A file or list of
   files that contain code which precompilation statements should be recorded from.

- `precompile_statements_file::Union{String, Vector{String}}`: A file or list of
   files that contains precompilation statements that should be included in the sysimage
   for the library.

- `incremental::Bool`: If `true`, build the new sysimage on top of the sysimage
   of the current process otherwise build a new sysimage from scratch. Defaults to `false`.

- `filter_stdlibs::Bool`: If `true`, only include stdlibs that are in the project file.
   Defaults to `false`, only set to `true` if you know the potential pitfalls.

- `audit::Bool`: Warn about eventual relocatability problems with the library, defaults
   to `true`.

- `force::Bool`: Remove the folder `compiled_lib` if it exists before creating the library.

- `header_files::Vector{String}`: A list of header files to include in the library bundle.

- `julia_init_c_file::String`: File to include in the system image with functions for
   initializing julia from external code.

- `version::VersionNumber`: Library version number.  Added to the sysimg `.so` name
   on Linux, and the `.dylib` name on Apple platforms, and with `compat_level`, used to
   determine and set the `current_version`, `compatibility_version` (on Apple) and
   `soname` (on Linux/UNIX)

- `compat_level::String`: compatibility level for library.  One of "major", "minor".
   Used to determine and set the `compatibility_version` (on Apple) and `soname` (on
   Linux/UNIX).

### Advanced keyword arguments

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image.
"""
function create_library(package_dir::String,
                        dest_dir::String;
                        lib_name=nothing,
                        precompile_execution_file::Union{String, Vector{String}}=String[],
                        precompile_statements_file::Union{String, Vector{String}}=String[],
                        incremental=false,
                        filter_stdlibs=false,
                        audit=true,
                        force=false,
                        header_files::Vector{String} = String[],
                        julia_init_c_file::String=joinpath(@__DIR__, "julia_init.c"),
                        version=nothing,
                        compat_level="major",
                        cpu_target::String=default_app_cpu_target())

    julia_init_h_file::String=joinpath(@__DIR__, "julia_init.h")

    if !(julia_init_h_file in header_files)
        push!(header_files, julia_init_h_file)
    end

    if version isa String
        version = parse(VersionNumber, version)
    end

    _create_app(package_dir, dest_dir, lib_name, precompile_execution_file,
        precompile_statements_file, incremental, filter_stdlibs, audit, force, cpu_target,
        library_only=true, julia_init_c_file=julia_init_c_file, header_files=header_files,
        version=version, compat_level=compat_level)

end

function _create_app(package_dir::String,
                    dest_dir::String,
                    name,
                    precompile_execution_file,
                    precompile_statements_file,
                    incremental,
                    filter_stdlibs,
                    audit,
                    force,
                    cpu_target::String;
                    library_only::Bool=false,
                    c_driver_program::String="",
                    julia_init_c_file=nothing,
                    header_files::Vector{String}=String[],
                    version=nothing,
                    compat_level::String="major")

    isapp = !library_only

    precompile_statements_file = abspath.(precompile_statements_file)
    precompile_execution_file = abspath.(precompile_execution_file)
    package_dir = abspath(package_dir)
    ctx = create_pkg_context(package_dir)
    if VERSION >= v"1.6.0-DEV.1673"
        Pkg.instantiate(ctx, verbose=true, allow_autoprecomp = false)
    else
        Pkg.instantiate(ctx, verbose=true)
    end
    if isempty(ctx.env.manifest)
        @warn "it is not recommended to create an app without a preexisting manifest"
    end
    if ctx.env.pkg === nothing
        error("expected package to have a `name`-entry")
    end
    sysimg_name = ctx.env.pkg.name
    if name === nothing
        name = sysimg_name
    end

    sysimg_file = get_sysimg_file(name, library_only=library_only, version=version)
    soname = get_soname(name,
                        library_only=library_only,
                        version=version,
                        compat_level=compat_level)

    if isdir(dest_dir)
        if !force
            error("directory $(repr(dest_dir)) already exists, use `force=true` to overwrite (will completely",
                  " remove the directory)")
        end
        rm(dest_dir; force=true, recursive=true)
    end

    audit && audit_app(ctx)

    mkpath(dest_dir)

    bundle_julia_libraries(dest_dir, library_only)
    bundle_artifacts(ctx, dest_dir, library_only)

    library_only && bundle_headers(dest_dir, header_files)

    # TODO: Create in a temp dir and then move it into place?
    target_path = Sys.isunix() && library_only ? joinpath(dest_dir, "lib") : joinpath(dest_dir, "bin")
    mkpath(target_path)
    cd(target_path) do
        if !incremental
            tmp = mktempdir()
            # Use workaround at https://github.com/JuliaLang/julia/issues/34064#issuecomment-563950633
            # by first creating a normal "empty" sysimage and then use that to finally create the one
            # with the @ccallable function
            tmp_base_sysimage = joinpath(tmp, "tmp_sys.so")
            create_sysimage(Symbol[]; sysimage_path=tmp_base_sysimage, project=package_dir,
                            incremental=false, filter_stdlibs=filter_stdlibs,
                            cpu_target=cpu_target)

            create_sysimage(Symbol(sysimg_name); sysimage_path=sysimg_file, project=package_dir,
                            incremental=true,
                            precompile_execution_file=precompile_execution_file,
                            precompile_statements_file=precompile_statements_file,
                            cpu_target=cpu_target,
                            base_sysimage=tmp_base_sysimage,
                            isapp=isapp,
                            julia_init_c_file=julia_init_c_file,
                            version=version,
                            soname=soname)
        else
            create_sysimage(Symbol(sysimg_name); sysimage_path=sysimg_file, project=package_dir,
                                              incremental=incremental, filter_stdlibs=filter_stdlibs,
                                              precompile_execution_file=precompile_execution_file,
                                              precompile_statements_file=precompile_statements_file,
                                              cpu_target=cpu_target,
                                              isapp=isapp,
                                              julia_init_c_file=julia_init_c_file,
                                              version=version,
                                              soname=soname)
        end

        if Sys.isapple()
            cmd = `install_name_tool -id @rpath/$sysimg_file $sysimg_file`
            @debug "running $cmd"
            run(cmd)
        end

        if !library_only
            c_driver_program = abspath(c_driver_program)
            create_executable_from_sysimg(; sysimage_path=sysimg_file, executable_path=name,
                                         c_driver_program_path=c_driver_program)
        end

        if library_only && version !== nothing && Sys.isunix()
            compat_file = get_sysimg_file(name, library_only=library_only, version=version, level=compat_level)
            base_file = get_sysimg_file(name, library_only=library_only)
            @debug "creating symlinks for $compat_file and $base_file"
            symlink(sysimg_file, compat_file)
            symlink(sysimg_file, base_file)
        end
    end
    return
end

function create_executable_from_sysimg(;sysimage_path::String,
                                        executable_path::String,
                                        c_driver_program_path::String,)
    flags = join((cflags(), ldflags(), ldlibs()), " ")
    flags = Base.shell_split(flags)
    wrapper = c_driver_program_path
    compiler = get_compiler()
    m = something(march(), ``)
    cmd = `$compiler -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) $(bitflag()) $m -o $(executable_path) $(wrapper) $(sysimage_path) -O2 $(rpath()) $flags`
    @debug "running $cmd"
    run_with_env(cmd, compiler)
    return nothing
end

function bundle_julia_libraries(dest_dir, library_only)
    app_libdir = joinpath(dest_dir, Sys.isunix() ? "lib" : "bin")
    cp(julia_libdir(), app_libdir; force=true)
    # We do not want to bundle the sysimg (nor the backup sysimage):
    rm(joinpath(app_libdir, "julia", default_sysimg_name()); force=true)
    rm(joinpath(app_libdir, "julia", backup_default_sysimg_name()); force=true)
    # Remove debug symbol libraries
    if Sys.isapple()
        v = string(VERSION.major, ".", VERSION.minor)
        rm(joinpath(app_libdir, "libjulia.$v.dylib.dSYM"); force=true, recursive=true)
        rm(joinpath(app_libdir, "julia", "sys.dylib.dSYM"); force=true, recursive=true)
    end
    return
end

function bundle_artifacts(ctx, dest_dir, library_only)
    @debug "bundling artifacts..."

    pkgs = load_all_deps(ctx)

    # Also want artifacts for the project itself
    @assert ctx.env.pkg !== nothing
    # This is kinda ugly...
    ctx.env.pkg.path = dirname(ctx.env.project_file)
    push!(pkgs, ctx.env.pkg)

    # Collect all artifacts needed for the project
    artifact_paths = Set{String}()
    for pkg in pkgs
        pkg_source_path = source_path(ctx, pkg)
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
    depot_path = get_depot_path(dest_dir, library_only)
    artifact_app_path = joinpath(depot_path, "artifacts")

    if !isempty(artifact_paths)
        mkpath(artifact_app_path)
    end
    for artifact_path in artifact_paths
        artifact_name = basename(artifact_path)
        cp(artifact_path, joinpath(artifact_app_path, artifact_name))
    end
    return
end

function bundle_headers(dest_dir, header_files)
    isempty(header_files) && return
    include_dir = joinpath(dest_dir, "include")
    mkpath(include_dir)

    for header_file in header_files
        new_file = joinpath(include_dir, basename(header_file))
        cp(header_file, new_file; force=true)
    end
    return
end

end # module
