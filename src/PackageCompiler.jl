module PackageCompiler

using Base: active_project
using Libdl: Libdl
using Pkg: Pkg
using Printf
using Artifacts
using LazyArtifacts
using UUIDs: UUID, uuid1
using RelocatableFolders

export create_sysimage, create_app, create_library

include("juliaconfig.jl")
include("../ext/TerminalSpinners.jl")


##############
# Arch utils #
##############

const NATIVE_CPU_TARGET = "native"
const TLS_SYNTAX = VERSION >= v"1.7.0-DEV.1205" ? `-DNEW_DEFINE_FAST_TLS_SYNTAX` : ``

const DEFAULT_EMBEDDING_WRAPPER = @path joinpath(@__DIR__, "embedding_wrapper.c")
const DEFAULT_JULIA_INIT        = @path joinpath(@__DIR__, "julia_init.c")
const DEFAULT_JULIA_INIT_HEADER = @path joinpath(@__DIR__, "julia_init.h")

# See https://github.com/JuliaCI/julia-buildbot/blob/489ad6dee5f1e8f2ad341397dc15bb4fce436b26/master/inventory.py
function default_app_cpu_target()
    Sys.ARCH === :i686        ?  "pentium4;sandybridge,-xsaveopt,clone_all"                        :
    Sys.ARCH === :x86_64      ?  "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"  :
    Sys.ARCH === :arm         ?  "armv7-a;armv7-a,neon;armv7-a,neon,vfp4"                          :
    Sys.ARCH === :aarch64     ?  "generic"   #= is this really the best here? =#                   :
    Sys.ARCH === :powerpc64le ?  "pwr8"                                                            :
        "generic"
end

function bitflag()
    Sys.ARCH === :i686   ? `-m32` :
    Sys.ARCH === :x86_64 ? `-m64` :
        ``
end

function march()
    Sys.ARCH === :i686        ? `-march=pentium4`            :
    Sys.ARCH === :x86_64      ? `-march=x86-64`              :
    Sys.ARCH === :arm         ? `-march=armv7-a+simd`        :
    Sys.ARCH === :aarch64     ? `-march=armv8-a+crypto+simd` :
    Sys.ARCH === :powerpc64le ? ``                           :
        ``
end


#############
# Pkg utils #
#############

function create_pkg_context(project)
    project_toml_path = Pkg.Types.projectfile_path(project; strict=true)
    if project_toml_path === nothing
        error("could not find project at $(repr(project))")
    end
    ctx = Pkg.Types.Context(env=Pkg.Types.EnvCache(project_toml_path))
    if isempty(ctx.env.manifest)
        @warn "it is not recommended to create an app/library without a preexisting manifest"
    end
    return ctx
end

function load_all_deps(ctx)
    ctx_or_env = VERSION <= v"1.7.0-" ? ctx : ctx.env
    if isdefined(Pkg.Operations, :load_all_deps!)
        pkgs = Pkg.Types.PackageSpec[]
        Pkg.Operations.load_all_deps!(ctx_or_env, pkgs)
    else
        pkgs = Pkg.Operations.load_all_deps(ctx_or_env)
    end
    return pkgs
end

function source_path(ctx, pkg)
    if VERSION <= v"1.7.0-"
        Pkg.Operations.source_path(ctx, pkg)
    else
        Pkg.Operations.source_path(ctx.env.project_file, pkg)
    end
end

const _STDLIBS = readdir(Sys.STDLIB)
sysimage_modules() = map(x->x.name, Base._sysimage_modules)
stdlibs_in_sysimage() = intersect(_STDLIBS, sysimage_modules())

# TODO: Also check UUIDs for stdlibs, not only names
function gather_stdlibs_project(ctx)
    @assert ctx.env.manifest !== nothing
    sysimage_stdlibs = stdlibs_in_sysimage()
    return String[pkg.name for (_, pkg) in ctx.env.manifest if pkg.name in sysimage_stdlibs]
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


##############
# Misc utils #
##############

const WARNED_CPP_COMPILER = Ref{Bool}(false)

function run_compiler(cmd::Cmd; cplusplus::Bool=false)
    cc = get(ENV, "JULIA_CC", nothing)
    path = nothing
    @static if Sys.iswindows()
        path = joinpath(LazyArtifacts.artifact"mingw-w64", (Int==Int64 ? "mingw64" : "mingw32"), "bin", cplusplus ? "g++.exe" : "gcc.exe")
        compiler_cmd = `$path`
    end
    if cc !== nothing
        compiler_cmd = Cmd(Base.shell_split(cc))
        path = nothing
    elseif !Sys.iswindows()
        compilers_cpp = ("g++", "clang++")
        compilers_c = ("gcc", "clang")
        found_compiler = false
        if cplusplus
            for compiler in compilers_cpp
                if Sys.which(compiler) !== nothing
                    compiler_cmd = `$compiler`
                    found_compiler = true
                    break
                end
            end
        end
        if !found_compiler
            for compiler in compilers_c
                if Sys.which(compiler) !== nothing
                    compiler_cmd = `$compiler`
                    found_compiler = true
                    if cplusplus && !WARNED_CPP_COMPILER[]
                        @warn "could not find a c++ compiler (g++ or clang++), falling back to $compiler, this might cause link errors"
                        WARNED_CPP_COMPILER[] = true
                    end
                    break
                end
            end
        end
        found_compiler || error("could not find a compiler, looked for ",
            join(((cplusplus ? compilers_cpp : ())..., compilers_c...), ", ", " and "))
    end
    if path !== nothing
        compiler_cmd = addenv(compiler_cmd, "PATH" => string(ENV["PATH"], ";", dirname(path)))
    end
    full_cmd = `$compiler_cmd $cmd`
    @debug "running $full_cmd"
    run(full_cmd)
end

function get_julia_cmd()
    julia_path = joinpath(Sys.BINDIR, Base.julia_exename())
    color = Base.have_color === nothing ? "auto" : Base.have_color ? "yes" : "no"
    return `$julia_path --color=$color --startup-file=no`
end


function rewrite_sysimg_jl_only_needed_stdlibs(stdlibs::Vector{String})
    sysimg_source_path = Base.find_source_file("sysimg.jl")
    sysimg_content = read(sysimg_source_path, String)
    # replaces the hardcoded list of stdlibs in sysimg.jl with
    # the stdlibs that is given as argument
    return replace(sysimg_content,
        r"stdlibs = \[(.*?)\]"s => string("stdlibs = [", join(":" .* stdlibs, ",\n"), "]"))
end

function create_fresh_base_sysimage(stdlibs::Vector{String}; cpu_target::String)
    tmp = mktempdir()
    sysimg_source_path = Base.find_source_file("sysimg.jl")
    base_dir = dirname(sysimg_source_path)
    tmp_corecompiler_ji = joinpath(tmp, "corecompiler.ji")
    tmp_sys_ji = joinpath(tmp, "sys.ji")
    compiler_source_path = joinpath(base_dir, "compiler", "compiler.jl")

    spinner = TerminalSpinners.Spinner(msg = "PackageCompiler: compiling base system image (incremental=false)")
    TerminalSpinners.@spin spinner begin
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
    end

    return tmp_sys_ji
end

function ensurecompiled(project, packages, sysimage)
    length(packages) == 0 && return
    # TODO: Only precompile `packages` (should be available in Pkg 1.8)
    cmd = `$(get_julia_cmd()) --sysimage=$sysimage -e 'using Pkg; Pkg.precompile()'`
    splitter = Sys.iswindows() ? ';' : ':'
    cmd = addenv(cmd, "JULIA_LOAD_PATH" => "$project$(splitter)@stdlib")
    run(cmd)
    return
end

function run_precompilation_script(project::String, sysimg::String, precompile_file::Union{String, Nothing}, precompile_dir::String)
    tracefile, io = mktemp(precompile_dir; cleanup=false)
    close(io)
    arg = precompile_file === nothing ? `-e ''` : `$precompile_file`
    cmd = `$(get_julia_cmd()) --sysimage=$(sysimg) --compile=all --trace-compile=$tracefile $arg`
    # --project is not propagated well with Distributed, so use environment
    splitter = Sys.iswindows() ? ';' : ':'
    cmd = addenv(cmd, "JULIA_LOAD_PATH" => "$project$(splitter)@stdlib")
    precompile_file === nothing || @info "PackageCompiler: Executing $(abspath(precompile_file)) => $(tracefile)"
    run(cmd)  # `Run` this command so that we'll display stdout from the user's script.
    precompile_file === nothing || @info "PackageCompiler: Done"
    return tracefile
end

function create_sysimg_object_file(object_file::String,
                            packages::Vector{String},
                            packages_sysimg::Set{Base.PkgId};
                            project::String,
                            base_sysimage::String,
                            precompile_execution_file::Vector{String},
                            precompile_statements_file::Vector{String},
                            cpu_target::String,
                            script::Union{Nothing, String},
                            sysimage_build_args::Cmd,
                            extra_precompiles::String)
    # Handle precompilation
    precompile_files = String[]
    @debug "running precompilation execution script..."
    precompile_dir = mktempdir(; prefix="jl_packagecompiler_", cleanup=false)
    for file in (isempty(precompile_execution_file) ? (nothing,) : precompile_execution_file)
        tracefile = run_precompilation_script(project, base_sysimage, file, precompile_dir)
        push!(precompile_files, tracefile)
    end
    append!(precompile_files, abspath.(precompile_statements_file))
    precompile_code = """
        # This @eval prevents symbols from being put into Main
        @eval Module() begin
            using Base.Meta
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
                try
                    # println(statement)
                    # This is taken from https://github.com/JuliaLang/julia/blob/2c9e051c460dd9700e6814c8e49cc1f119ed8b41/contrib/generate_precompile.jl#L375-L393
                    ps = Meta.parse(statement)
                    isexpr(ps, :call) || continue
                    popfirst!(ps.args) # precompile(...)
                    ps.head = :tuple
                    l = ps.args[end]
                    if (isexpr(l, :tuple) || isexpr(l, :curly)) && length(l.args) > 0 # Tuple{...} or (...)
                        # XXX: precompile doesn't currently handle overloaded Vararg arguments very well.
                        # Replacing N with a large number works around it.
                        l = l.args[end]
                        if isexpr(l, :curly) && length(l.args) == 2 && l.args[1] === :Vararg # Vararg{T}
                            push!(l.args, 100) # form Vararg{T, 100} instead
                        end
                    end
                    # println(ps)
                    ps = Core.eval(PrecompileStagingArea, ps)
                    # XXX: precompile doesn't currently handle overloaded nospecialize arguments very well.
                    # Skipping them avoids the warning.
                    ms = length(ps) == 1 ? Base._methods_by_ftype(ps[1], 1, Base.get_world_counter()) : Base.methods(ps...)
                    ms isa Vector || continue
                    precompile(ps...)
                catch e
                    # See julia issue #28808
                    @debug "failed to execute \$statement"
                end
            end
            @eval PrecompileStagingArea begin
                $extra_precompiles
            end
        end # module
        """

    julia_code_buffer = IOBuffer()
    # include all packages into the sysimg
    print(julia_code_buffer, """
        Base.reinit_stdio()
        @eval Sys BINDIR = ccall(:jl_get_julia_bindir, Any, ())::String
        @eval Sys STDLIB = $(repr(abspath(Sys.BINDIR, "../share/julia/stdlib", string('v', VERSION.major, '.', VERSION.minor))))
        copy!(LOAD_PATH, [$(repr(project))]) # Only allow loading packages from current project
        Base.init_depot_path()
        """)

    for pkg in packages_sysimg
        print(julia_code_buffer, """
            Base.require(Base.PkgId(Base.UUID("$(string(pkg.uuid))"), $(repr(pkg.name))))
            """)
    end

    # Make packages available in Main. It is unclear if this is the right thing to do.
    for pkg in packages
        print(julia_code_buffer, """
            import $pkg
            """)
    end

    print(julia_code_buffer, precompile_code)

    if script !== nothing
        print(julia_code_buffer, """
        include($(repr(abspath(script))))
        """)
    end

    print(julia_code_buffer, """
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        """)

    julia_code = String(take!(julia_code_buffer))
    outputo_file = tempname()
    write(outputo_file, julia_code)
    # Read the input via stdin to avoid hitting the maximum command line limit

    cmd = `$(get_julia_cmd()) --cpu-target=$cpu_target -O3 $sysimage_build_args
                              --sysimage=$base_sysimage --project=$project --output-o=$(object_file) $outputo_file`
    @debug "running $cmd"
    spinner = TerminalSpinners.Spinner(msg = "PackageCompiler: compiling incremental system image")
    TerminalSpinners.@spin spinner run(cmd)
    return
end

"""
    create_sysimage(packages::Vector{String}; kwargs...)

Create a system image that includes the package(s) in `packages` (given as a
string or vector). If the `packages` argument is not passed, all packages in the
project will be put into the sysimage.

An attempt to automatically find a compiler will be done but can also be given
explicitly by setting the environment variable `JULIA_CC` to a path to a
compiler (can also include extra arguments to the compiler, like `-g`).

### Keyword arguments:

- `sysimage_path::String`: The path to where the resulting sysimage should be saved.

- `project::String`: The project that should be active when the sysimage is created,
  defaults to the currently active project.

- `precompile_execution_file::Union{String, Vector{String}}`: A file or list of
  files that contain code from which precompilation statements should be recorded.

- `precompile_statements_file::Union{String, Vector{String}}`: A file or list of
  files that contain precompilation statements that should be included in the sysimage.

- `incremental::Bool`: If `true`, build the new sysimage on top of the sysimage
  of the current process otherwise build a new sysimage from scratch. Defaults to `true`.

- `filter_stdlibs::Bool`: If `true`, only include stdlibs that are in the project file.
  Defaults to `false`, only set to `true` if you know the potential pitfalls.

- `include_transitive_dependencies::Bool`: If `true`, explicitly put all
   transitive dependencies into the sysimage. This only makes a difference if some
   packages do not load all their dependencies when themselves are loaded. Defaults to `true`.

### Advanced keyword arguments

- `base_sysimage::Union{Nothing, String}`: If a `String`, names an existing sysimage upon which to build
   the new sysimage incrementally, instead of the sysimage of the current process. Defaults to `nothing`.
   Keyword argument `incremental` must be `true` if `base_sysimage` is not `nothing`.

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image. Defaults
  to `native`.

- `script::String`: Path to a file that gets executed in the `--output-o` process.

- `sysimage_build_args::Cmd`: A set of command line options that is used in the Julia process building the sysimage,
  for example `-O1 --check-bounds=yes`.
"""
function create_sysimage(packages::Union{Nothing, Symbol, Vector{String}, Vector{Symbol}}=nothing;
                         sysimage_path::String,
                         project::String=dirname(active_project()),
                         precompile_execution_file::Union{String, Vector{String}}=String[],
                         precompile_statements_file::Union{String, Vector{String}}=String[],
                         incremental::Bool=true,
                         filter_stdlibs::Bool=false,
                         cpu_target::String=NATIVE_CPU_TARGET,
                         script::Union{Nothing, String}=nothing,
                         sysimage_build_args::Cmd=``,
                         include_transitive_dependencies::Bool=true,
                         # Internal args
                         base_sysimage::Union{Nothing, String}=nothing,
                         julia_init_c_file=nothing,
                         version=nothing,
                         soname=nothing,
                         compat_level::String="major",
                         extra_precompiles::String = "",
                         )

    if filter_stdlibs && incremental
        error("must use `incremental=false` to use `filter_stdlibs=true`")
    end

    ctx = create_pkg_context(project)

    if packages === nothing
        packages = collect(keys(ctx.env.project.deps))
        if ctx.env.pkg !== nothing
            push!(packages, ctx.env.pkg.name)
        end
    end

    packages = string.(vcat(packages))
    precompile_execution_file  = vcat(precompile_execution_file)
    precompile_statements_file = vcat(precompile_statements_file)

    check_packages_in_project(ctx, packages)

    # Instantiate the project

    @debug "instantiating project at $(repr(project))"
    Pkg.instantiate(ctx, verbose=true, allow_autoprecomp = false)

    if !incremental
        if base_sysimage !== nothing
            error("cannot specify `base_sysimage`  when `incremental=false`")
        end
        sysimage_stdlibs = filter_stdlibs ? gather_stdlibs_project(ctx) : stdlibs_in_sysimage()
        base_sysimage = create_fresh_base_sysimage(sysimage_stdlibs; cpu_target)
    else
        base_sysimage = something(base_sysimage, unsafe_string(Base.JLOptions().image_file))
    end

    ensurecompiled(project, packages, base_sysimage)

    packages_sysimg = Set{Base.PkgId}()

    if include_transitive_dependencies
        # We are not sure that packages actually load their dependencies on `using`
        # but we still want them to end up in the sysimage. Therefore, explicitly
        # collect their dependencies, recursively.

        frontier = Set{Base.PkgId}()
        deps = ctx.env.project.deps
        for pkg in packages
            # Add all dependencies of the package
            if ctx.env.pkg !== nothing && pkg == ctx.env.pkg.name
                push!(frontier, Base.PkgId(ctx.env.pkg.uuid, pkg))
            else
                uuid = ctx.env.project.deps[pkg]
                push!(frontier, Base.PkgId(uuid, pkg))
            end
        end
        copy!(packages_sysimg, frontier)
        new_frontier = Set{Base.PkgId}()
        while !(isempty(frontier))
            for pkgid in frontier
                deps = if ctx.env.pkg !== nothing && pkgid.uuid == ctx.env.pkg.uuid
                    ctx.env.project.deps
                else
                    ctx.env.manifest[pkgid.uuid].deps
                end
                pkgid_deps = [Base.PkgId(uuid, name) for (name, uuid) in deps]
                for pkgid_dep in pkgid_deps
                    if !(pkgid_dep in packages_sysimg) #
                        push!(packages_sysimg, pkgid_dep)
                        push!(new_frontier, pkgid_dep)
                    end
                end
            end
            copy!(frontier, new_frontier)
            empty!(new_frontier)
        end
    end

    # Create the sysimage
    object_file = tempname() * ".o"

    create_sysimg_object_file(object_file, packages, packages_sysimg;
                            project,
                            base_sysimage,
                            precompile_execution_file,
                            precompile_statements_file,
                            cpu_target,
                            script,
                            sysimage_build_args,
                            extra_precompiles)
    object_files = [object_file]
    if julia_init_c_file !== nothing
        push!(object_files, compile_c_init_julia(julia_init_c_file, basename(sysimage_path)))
    end
    create_sysimg_from_object_file(object_files,
                                sysimage_path;
                                compat_level,
                                version,
                                soname)

    rm(object_file; force=true)

    if Sys.isapple()
        cd(dirname(abspath(sysimage_path))) do
            sysimage_file = basename(sysimage_path)
            cmd = `install_name_tool -id @rpath/$(sysimage_file) $sysimage_file`
            run(cmd)
        end
    end

    return nothing
end

function create_sysimg_from_object_file(object_files::Vector{String},
                                        sysimage_path::String;
                                        version,
                                        compat_level::String,
                                        soname::Union{Nothing, String})

    if soname === nothing && (Sys.isunix() && !Sys.isapple())
        soname = basename(sysimage_path)
    end
    mkpath(dirname(sysimage_path))
    # Prevent compiler from stripping all symbols from the shared lib.
    o_file_flags = Sys.isapple() ? `-Wl,-all_load $object_files` : `-Wl,--whole-archive $object_files -Wl,--no-whole-archive`
    extra = get_extra_linker_flags(version, compat_level, soname)
    cmd = `$(bitflag()) $(march()) -shared -L$(julia_libdir()) -L$(julia_private_libdir()) -o $sysimage_path $o_file_flags $(Base.shell_split(ldlibs())) $extra`
    run_compiler(cmd; cplusplus=true)
    return nothing
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
    rpath_args = rpath_sysimage()

    extra = Sys.iswindows() ? `-Wl,--export-all-symbols` :
            Sys.isapple() ? `-fPIC $compat_ver_arg $current_ver_arg $rpath_args` :
            Sys.isunix() ? `-fPIC $soname_arg $rpath_args` :
                error("unknown machine type, not windows, macOS not UNIX")

    return extra
end

function compile_c_init_julia(julia_init_c_file::String, sysimage_name::String)
    @debug "Compiling $julia_init_c_file"
    flags = Base.shell_split(cflags())

    o_init_file = splitext(julia_init_c_file)[1] * ".o"
    cmd = `-c -O2 -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_name)) $TLS_SYNTAX $(bitflag()) $flags $(march()) -o $o_init_file $julia_init_c_file`
    run_compiler(cmd)
    return o_init_file
end


function try_rm_dir(dest_dir; force)
    if isdir(dest_dir)
        if !force
            error("directory $(repr(dest_dir)) already exists, use `force=true` to overwrite (will completely",
                " remove the directory)")
        end
        rm(dest_dir; force=true, recursive=true)
    end
end


#######
# App #
#######

const IS_OFFICIAL = occursin("Official https://julialang.org/ release", sprint(Base.banner))
function warn_official()
    if !IS_OFFICIAL
        @warn "PackageCompiler: This does not look like an official Julia build, functionality may suffer." _module=nothing _file=nothing
    end
end

"""
    create_app(package_dir::String, compiled_app::String; kwargs...)

Compile an app with the source in `package_dir` to the folder `compiled_app`.
The folder `package_dir` needs to contain a package where the package includes a
function with the signature

```julia
julia_main()::Cint
    # Perhaps do something based on ARGS
    ...
end
```

The executable will be placed in a folder called `bin` in `compiled_app` and
when the executable run the `julia_main` function is called.

Standard Julia arguments are set by passing them after a `--julia-args`
argument, for example:
```
\$ ./MyApp input.csv --julia-args -O3 -t8
```

An attempt to automatically find a compiler will be done but can also be given
explicitly by setting the environment variable `JULIA_CC` to a path to a
compiler (can also include extra arguments to the compiler, like `-g`).

### Keyword arguments:

- executables::`Vector{Pair{String, String}}:`: A list of executables to
  produce, given as pairs of `executable_name => julia_main` where
  `executable_name` is the name of the produced executable with the
  julia function `julia_main`. If not provided, the name
  of the package (as specified in `Project.toml`) is used and the main function
  in julia is taken as `julia_main`.

- `precompile_execution_file::Union{String, Vector{String}}`: A file or list of
  files that contain code from which precompilation statements should be recorded.

- `precompile_statements_file::Union{String, Vector{String}}`: A file or list of
  files that contain precompilation statements that should be included in the sysimage
  for the app.

- `incremental::Bool`: If `true`, build the new sysimage on top of the sysimage
  of the current process otherwise build a new sysimage from scratch. Defaults to `false`.

- `filter_stdlibs::Bool`: If `true`, only include stdlibs that are in the project file.
  Defaults to `false`, only set to `true` if you know the potential pitfalls.

- `force::Bool`: Remove the folder `compiled_app` if it exists before creating the app.

- `include_lazy_artifacts::Bool`: if lazy artifacts should be included in the bundled artifacts,
  defaults to `false`.

- `include_transitive_dependencies::Bool`: If `true`, explicitly put all
  transitive dependencies into the sysimage. This only makes a difference if some
  packages do not load all their dependencies when themselves are loaded. Defaults to `true`.

### Advanced keyword arguments

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image.

- `sysimage_build_args::Cmd`: A set of command line options that is used in the Julia process building the sysimage,
  for example `-O1 --check-bounds=yes`.
"""
function create_app(package_dir::String,
                    app_dir::String;
                    executables::Union{Nothing, Vector{Pair{String, String}}}=nothing,
                    precompile_execution_file::Union{String, Vector{String}}=String[],
                    precompile_statements_file::Union{String, Vector{String}}=String[],
                    incremental::Bool=false,
                    filter_stdlibs::Bool=false,
                    force::Bool=false,
                    c_driver_program::String=String(DEFAULT_EMBEDDING_WRAPPER),
                    cpu_target::String=default_app_cpu_target(),
                    include_lazy_artifacts::Bool=false,
                    sysimage_build_args::Cmd=``,
                    include_transitive_dependencies::Bool=true)
    warn_official()

    ctx = create_pkg_context(package_dir)
    ctx.env.pkg === nothing && error("expected package to have a `name`-entry")
    Pkg.instantiate(ctx, verbose=true, allow_autoprecomp = false)

    if executables === nothing
        executables = [ctx.env.pkg.name => "julia_main"]
    end
    try_rm_dir(app_dir; force)
    bundle_artifacts(ctx, app_dir; include_lazy_artifacts)
    bundle_julia_libraries(app_dir)
    bundle_julia_executable(app_dir)
    bundle_project(ctx, app_dir)

    sysimage_path = joinpath(app_dir, "lib", "julia", "sys." * Libdl.dlext)

    package_name = ctx.env.pkg.name
    project = dirname(ctx.env.project_file)

    # add precompile statements for functions that will be called from the C main() wrapper
    precompiles = String[]
    for (_, julia_main) in executables
        push!(precompiles, "isdefined($package_name, :$julia_main) && precompile(Tuple{typeof($package_name.$julia_main)})")
    end
    push!(precompiles, "precompile(Tuple{typeof(append!), Vector{String}, Vector{Any}})")
    push!(precompiles, "precompile(Tuple{typeof(empty!), Vector{String}})")
    push!(precompiles, "precompile(Tuple{typeof(popfirst!), Vector{String}})")

    create_sysimage([package_name]; sysimage_path, project,
                    incremental,
                    filter_stdlibs,
                    precompile_execution_file,
                    precompile_statements_file,
                    cpu_target,
                    sysimage_build_args,
                    include_transitive_dependencies,
                    extra_precompiles = join(precompiles, "\n"))

    for (app_name, julia_main) in executables
        create_executable_from_sysimg(joinpath(app_dir, "bin", app_name), c_driver_program, string(package_name, ".", julia_main))
    end
end


function create_executable_from_sysimg(exe_path::String,
                                       c_driver_program::String,
                                       julia_main::String)
    c_driver_program = abspath(c_driver_program)
    mkpath(dirname(exe_path))
    flags = Base.shell_split(join((cflags(), ldflags(), ldlibs()), " "))
    m = something(march(), ``)
    cmd = `-DJULIA_MAIN=\"$julia_main\" $TLS_SYNTAX $(bitflag()) $m -o $(exe_path) $(c_driver_program) -O2 $(rpath_executable()) $flags`
    run_compiler(cmd)
    return nothing
end


###########
# Library #
###########

"""
    create_library(package_dir::String, dest_dir::String; kwargs...)

Compile a library with the source in `package_dir` to the folder `dest_dir`.
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
it at run time. Options include

* Installing all libraries somewhere in the library search path.
* Adding `/path/to/libname` to an appropriate library search path environment
  variable (`DYLD_LIBRARY_PATH` on OSX, `PATH` on Windows, or `LD_LIBRARY_PATH`
  on Linux/BSD/Unix).
* Running `install_name_tool -change libname /path/to/libname` (OSX)

To use any Julia exported functions, you *must* first call `init_julia(argc, argv)`,
where `argc` and `argv` are parameters that would normally be passed to `julia` on the
command line (e.g., to set up the number of threads or processes).

When your program is exiting, it is also suggested to call `shutdown_julia(retcode)`,
to allow Julia to cleanly clean up resources and call any finalizers. (This function
simply calls `jl_atexit_hook(retcode)`.)

An attempt to automatically find a compiler will be done but can also be given
explicitly by setting the environment variable `JULIA_CC` to a path to a
compiler (can also include extra arguments to the compiler, like `-g`).

### Keyword arguments:

- `lib_name::String`: an alternative name for the compiled library. If not provided,
  the name of the package (as specified in Project.toml) is used. `lib` will be
  prepended to the name if it is not already present.

- `precompile_execution_file::Union{String, Vector{String}}`: A file or list of
  files that contain code from which precompilation statements should be recorded.

- `precompile_statements_file::Union{String, Vector{String}}`: A file or list of
  files that contain precompilation statements that should be included in the sysimage
  for the library.

- `incremental::Bool`: If `true`, build the new sysimage on top of the sysimage
  of the current process otherwise build a new sysimage from scratch. Defaults to `false`.

- `filter_stdlibs::Bool`: If `true`, only include stdlibs that are in the project file.
  Defaults to `false`, only set to `true` if you know the potential pitfalls.

- `force::Bool`: Remove the folder `compiled_lib` if it exists before creating the library.

- `header_files::Vector{String}`: A list of header files to include in the library bundle.

- `julia_init_c_file::String`: File to include in the system image with functions for
  initializing julia from external code.

- `version::VersionNumber`: Library version number. Added to the sysimg `.so` name
  on Linux, and the `.dylib` name on Apple platforms, and with `compat_level`, used to
  determine and set the `current_version`, `compatibility_version` (on Apple) and
  `soname` (on Linux/UNIX)

- `compat_level::String`: compatibility level for library. One of "major", "minor".
  Used to determine and set the `compatibility_version` (on Apple) and `soname` (on
  Linux/UNIX).

- `include_lazy_artifacts::Bool`: if lazy artifacts should be included in the bundled artifacts,
  defaults to `false`.

- `include_transitive_dependencies::Bool`: If `true`, explicitly put all
  transitive dependencies into the sysimage. This only makes a difference if some
  packages do not load all their dependencies when themselves are loaded. Defaults to `true`.

### Advanced keyword arguments

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image.

- `sysimage_build_args::Cmd`: A set of command line options that is used in the Julia process building the sysimage,
  for example `-O1 --check-bounds=yes`.
"""
function create_library(package_dir::String,
                        dest_dir::String;
                        lib_name=nothing,
                        precompile_execution_file::Union{String, Vector{String}}=String[],
                        precompile_statements_file::Union{String, Vector{String}}=String[],
                        incremental::Bool=false,
                        filter_stdlibs::Bool=false,
                        force::Bool=false,
                        header_files::Vector{String} = String[],
                        julia_init_c_file::String=String(DEFAULT_JULIA_INIT),
                        version::Union{String,VersionNumber,Nothing}=nothing,
                        compat_level::String="major",
                        cpu_target::String=default_app_cpu_target(),
                        include_lazy_artifacts::Bool=false,
                        sysimage_build_args::Cmd=``,
                        include_transitive_dependencies::Bool=true)


    warn_official()

    julia_init_h_file = String(DEFAULT_JULIA_INIT_HEADER)

    if !(julia_init_h_file in header_files)
        push!(header_files, julia_init_h_file)
    end

    if version isa String
        version = parse(VersionNumber, version)
    end

    ctx = create_pkg_context(package_dir)
    ctx.env.pkg === nothing && error("expected package to have a `name`-entry")
    Pkg.instantiate(ctx, verbose=true, allow_autoprecomp = false)

    lib_name = something(lib_name, ctx.env.pkg.name)
    try_rm_dir(dest_dir; force)
    mkpath(dest_dir)
    bundle_julia_libraries(dest_dir)
    bundle_artifacts(ctx, dest_dir; include_lazy_artifacts)
    bundle_headers(dest_dir, header_files)

    lib_dir = Sys.iswindows() ? joinpath(dest_dir, "bin") : joinpath(dest_dir, "lib")

    sysimg_file = get_library_filename(lib_name; version)
    sysimg_path = joinpath(lib_dir, sysimg_file)
    compat_file = get_library_filename(lib_name; version, compat_level)
    soname = (Sys.isunix() && !Sys.isapple()) ? compat_file : nothing

    create_sysimage_workaround(ctx, sysimg_path, precompile_execution_file,
        precompile_statements_file, incremental, filter_stdlibs, cpu_target;
        sysimage_build_args, include_transitive_dependencies, julia_init_c_file, version,
        soname)

    if version !== nothing && Sys.isunix()
        cd(dirname(sysimg_path)) do
            base_file = get_library_filename(lib_name)
            @debug "creating symlinks for $compat_file and $base_file"
            symlink(sysimg_file, compat_file)
            symlink(sysimg_file, base_file)
        end
    end
end

get_compat_version(version::VersionNumber, level::String) = VersionNumber(get_compat_version_str(version, level))
function get_compat_version_str(version::VersionNumber, level::String)
    level == "full"  ? "$(version)" :
    level == "patch" ? "$(version.major).$(version.minor).$(version.patch)" :
    level == "minor" ? "$(version.major).$(version.minor)" :
    level == "major" ? "$(version.major)" :
        error("Unknown level: $level")
end

function get_library_filename(name::String;
                              version::Union{VersionNumber, Nothing}=nothing,
                              compat_level::String="patch")

    dlext = Libdl.dlext
    Sys.iswindows() && return "$name.$dlext"

    # For libraries on Unix/Apple, make sure the name starts with "lib"
    if !startswith(name, "lib")
        name = "lib" * name
    end

    version === nothing && return "$name.$dlext"

    version = get_compat_version_str(version, compat_level)

    sysimg_file = (
        Sys.isapple() ? "$name.$version.$dlext" :  # libname.1.2.3.dylib
        Sys.isunix() ? "$name.$dlext.$version" :   # libname.so.1.2.3
        error("unable to determine sysimage_file; system is not Windows, macOS, or UNIX")
    )

    return sysimg_file
end

# Use workaround at https://github.com/JuliaLang/julia/issues/34064#issuecomment-563950633
# by first creating a normal "empty" sysimage and then use that to finally create the one
# with the @ccallable function.
# This function can be removed when https://github.com/JuliaLang/julia/pull/37530 is merged
function create_sysimage_workaround(
                    ctx,
                    sysimage_path::String,
                    precompile_execution_file::Union{String, Vector{String}},
                    precompile_statements_file::Union{String, Vector{String}},
                    incremental::Bool,
                    filter_stdlibs::Bool,
                    cpu_target::String;
                    sysimage_build_args::Cmd,
                    include_transitive_dependencies::Bool,
                    julia_init_c_file::Union{Nothing,String},
                    version::Union{Nothing,VersionNumber},
                    soname::Union{Nothing,String}
                    )
    package_name = ctx.env.pkg.name
    project = dirname(ctx.env.project_file)

    if !incremental
        tmp = mktempdir()
        base_sysimage = joinpath(tmp, "tmp_sys." * Libdl.dlext)
        create_sysimage(String[]; sysimage_path=base_sysimage, project,
                        incremental=false, filter_stdlibs, cpu_target)
    else
        base_sysimage = nothing
    end

    create_sysimage([package_name]; sysimage_path, project,
                    incremental=true,
                    precompile_execution_file,
                    precompile_statements_file,
                    cpu_target,
                    base_sysimage,
                    julia_init_c_file,
                    version,
                    soname,
                    sysimage_build_args,
                    include_transitive_dependencies)

    return
end
############
# Bundling #
############

# One of the main reason for bundling the project file is
# for Distributed to work. When using Distributed we need to
# load packages on other workers and that requires the Project file.
# See https://github.com/JuliaLang/julia/issues/42296 for some discussion.
function bundle_project(ctx, dir)
    julia_share =  joinpath(dir, "share", "julia")
    mkpath(julia_share)
    # We do not want to bundle some potentially sensitive data, only data that
    # is already trivially retrievable from the sysimage.
    d = Dict{String, Any}()
    d["name"] = ctx.env.project.name
    d["uuid"] = ctx.env.project.uuid
    d["deps"] = ctx.env.project.deps

    Pkg.Types.write_project(d, joinpath(julia_share, "Project.toml"))
end

function bundle_julia_executable(dir::String)
    bindir = joinpath(dir, "bin")
    name = Sys.iswindows() ? "julia.exe" : "julia"
    mkpath(bindir)
    cp(joinpath(Sys.BINDIR::String, name), joinpath(bindir, name); force=true)
end

function bundle_julia_libraries(dest_dir)
    app_libdir = joinpath(dest_dir, Sys.isunix() ? "lib" : "bin")
    mkpath(app_libdir)
    cp(julia_libdir(), app_libdir; force=true)
    # We do not want to bundle the sysimg
    default_sysimg_name = "sys." * Libdl.dlext
    rm(joinpath(app_libdir, "julia", default_sysimg_name); force=true)
    # Remove debug symbol libraries
    if Sys.isapple()
        v = string(VERSION.major, ".", VERSION.minor)
        rm(joinpath(app_libdir, "libjulia.$v.dylib.dSYM"); force=true, recursive=true)
        rm(joinpath(app_libdir, "julia", "sys.dylib.dSYM"); force=true, recursive=true)
    end
    return
end

function recursive_dir_size(path)
    size = 0
    try
        for (root, dirs, files) in walkdir(path)
            for file in files
                path = joinpath(root, file)
                try
                    size += lstat(path).size
                catch ex
                    @error("Failed to calculate size of $path", exception=ex)
                end
            end
        end
    catch ex
        @error("Failed to calculate size of $path", exception=ex)
    end
    return size
end

function pretty_byte_str(size)
    bytes, mb = Base.prettyprint_getunits(size, length(Base._mem_units), Int64(1024))
    return @sprintf("%.3f %s", bytes, Base._mem_units[mb])
end

function bundle_artifacts(ctx, dest_dir; include_lazy_artifacts::Bool)
    pkgs = load_all_deps(ctx)

    # Also want artifacts for the project itself
    @assert ctx.env.pkg !== nothing
    # This is kinda ugly...
    ctx.env.pkg.path = dirname(ctx.env.project_file)
    push!(pkgs, ctx.env.pkg)

    # TODO: Allow override platform?
    platform = Base.BinaryPlatforms.HostPlatform()
    depot_path = joinpath(dest_dir, "share", "julia")
    artifact_app_path = joinpath(depot_path, "artifacts")

    bundled_artifacts = Pair{String, Vector{Pair{String, String}}}[]

    for pkg in pkgs
        pkg_source_path = source_path(ctx, pkg)
        pkg_source_path === nothing && continue
        bundled_artifacts_pkg = Pair{String, String}[]
        # Check to see if this package has an (Julia)Artifacts.toml
        for f in Pkg.Artifacts.artifact_names
            artifacts_toml_path = joinpath(pkg_source_path, f)
            if isfile(artifacts_toml_path)
                artifacts = Artifacts.select_downloadable_artifacts(artifacts_toml_path; platform, include_lazy=include_lazy_artifacts)
                for name in keys(artifacts)
                    artifact_path = Pkg.ensure_artifact_installed(name, artifacts[name], artifacts_toml_path; platform)
                    push!(bundled_artifacts_pkg, name => artifact_path)
                end
                break
            end
        end
        if !isempty(bundled_artifacts_pkg)
            push!(bundled_artifacts, pkg.name => bundled_artifacts_pkg)
        end
    end

    if !isempty(bundled_artifacts)
        printstyled("PackageCompiler: bundled artifacts:\n")
        mkpath(artifact_app_path)
    end

    total_size = 0
    sort!(bundled_artifacts)

    bundled_shas = Set{String}()
    for (i, (pkg, artifacts)) in enumerate(bundled_artifacts)
        last_pkg = i == length(bundled_artifacts)
        mark_pkg = last_pkg ? "└──" : "├──"
        print("  $mark_pkg $pkg")
        # jlls often only have a single artifact with the same name as the package itself
        std_jll = endswith(pkg, "_jll") && length(artifacts) == 1
        if !std_jll
            println()
        end
        for (j, (artifact, artifact_path)) in enumerate(artifacts)
            git_tree_sha_artifact = basename(artifact_path)
            already_bundled = git_tree_sha_artifact in bundled_shas
            size = already_bundled ? 0 : recursive_dir_size(artifact_path)
            total_size += size
            size_str = already_bundled ? "[already bundled]" : pretty_byte_str(size)
            if std_jll
                println(" - ", size_str, "")
            else
                mark_artifact = j == length(artifacts) ? "└──" : "├──"
                mark_init = last_pkg ? " " : "│"
                println("  $mark_init   ", mark_artifact, " ", artifact, " - ", size_str, "")
            end
            if !already_bundled
                cp(artifact_path, joinpath(artifact_app_path, git_tree_sha_artifact))
                push!(bundled_shas, git_tree_sha_artifact)
            end
        end
    end
    if total_size > 0
        println("  Total artifact file size: ", pretty_byte_str(total_size))
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
