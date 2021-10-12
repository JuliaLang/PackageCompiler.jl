module PackageCompiler

using Base: active_project
using Libdl: Libdl
using Pkg: Pkg
using Artifacts
using LazyArtifacts
using UUIDs: UUID, uuid1
using RelocatableFolders

export create_sysimage, create_app, create_library, audit_app, restore_default_sysimage

include("juliaconfig.jl")

const NATIVE_CPU_TARGET = "native"
const TLS_SYNTAX = VERSION >= v"1.7.0-DEV.1205" ? `-DNEW_DEFINE_FAST_TLS_SYNTAX` : ``

const DEFAULT_EMBEDDING_WRAPPER = @path joinpath(@__DIR__, "embedding_wrapper.c")
const DEFAULT_JULIA_INIT = @path joinpath(@__DIR__, "julia_init.c")
const DEFAULT_JULIA_INIT_HEADER = @path joinpath(@__DIR__, "julia_init.h")


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
sysimage_modules() = map(x->x.name, Base._sysimage_modules)
stdlibs_in_sysimage() = intersect(all_stdlibs(), sysimage_modules())
stdlibs_not_in_sysimage() = setdiff(all_stdlibs(), sysimage_modules())

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

function run_compiler(cmd::Cmd)
    cc = get(ENV, "JULIA_CC", nothing)
    path = nothing
    @static if Sys.iswindows()
        path = joinpath(LazyArtifacts.artifact"mingw-w64", (Int==Int64 ? "mingw64" : "mingw32"), "bin", "gcc.exe")
        compiler_cmd = `$path`
    end
    if cc !== nothing
        compiler_cmd = Cmd(Base.shell_split(cc))
        path = nothing
    elseif !Sys.iswindows()
        if Sys.which("gcc") !== nothing
            compiler_cmd = `gcc`
        elseif Sys.which("clang") !== nothing
            compiler_cmd = `clang`
        else
            error("could not find a compiler, looked for `gcc` and `clang`")
        end
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
    return `$julia_path --color=yes --startup-file=no`
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
                     compat_level::String="patch")

    dlext = Libdl.dlext
    (!library_only || Sys.iswindows()) && return "sys.$dlext"

    # For libraries on Unix/Apple, make sure the name starts with "lib"
    if !startswith(name, "lib")
        name = "lib" * name
    end

    if version === nothing
        return "$name.$dlext"
    end

    version = get_compat_version_str(version, compat_level)
    sysimg_file = (
        Sys.isapple() ? "$name.$version.$dlext" :  # libname.1.2.3.dylib
        Sys.isunix() ? "$name.$dlext.$version" :   # libname.so.1.2.3
        error("Unable to determine sysimage_file; system is not Windows, Apple, or UNIX!")
    )

    return sysimg_file
end

function get_soname(name::String;
                library_only::Bool=false,
                version::Union{VersionNumber, Nothing}=nothing,
                compat_level::String="major")

    (!Sys.isunix() || Sys.isapple()) && return nothing
    return get_sysimg_file(name; library_only, version, compat_level)
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
    if precompile_file === nothing
        arg = `-e ''`
    else
        arg = `$precompile_file`
    end
    cmd = `$(get_julia_cmd()) --sysimage=$(sysimg)
            --compile=all --trace-compile=$tracefile $arg`
    # --project is not propagated well with Distributed, so use environment
    splitter = Sys.iswindows() ? ';' : ':'
    cmd = addenv(cmd, "JULIA_LOAD_PATH" => "$project$(splitter)@stdlib")
    precompile_file === nothing || @info "PackageCompiler: Executing $(precompile_file) => $(tracefile)"
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
                            isapp::Bool,
                            sysimage_build_args::Cmd)

    ensurecompiled(project, packages, base_sysimage)
    # Handle precompilation
    precompile_files = String[]
    @debug "running precompilation execution script..."
    precompile_dir = mktempdir(; prefix="jl_packagecompiler_", cleanup=false)
    for file in (isempty(precompile_execution_file) ? (nothing,) : precompile_execution_file)
        tracefile = run_precompilation_script(project, base_sysimage, file, precompile_dir)
        push!(precompile_files, tracefile)
    end
    append!(precompile_files, precompile_statements_file)
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
        end # module
        """

    julia_code_buffer = IOBuffer()
    # include all packages into the sysimg
    print(julia_code_buffer, """
        Base.reinit_stdio()
        @eval Sys BINDIR = ccall(:jl_get_julia_bindir, Any, ())::String
        @eval Sys STDLIB = $(repr(abspath(Sys.BINDIR, "../share/julia/stdlib", string('v', VERSION.major, '.', VERSION.minor))))
        Base.init_load_path()
        if isdefined(Base, :init_active_project)
            Base.init_active_project()
        end
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

    if isapp
        # If it is an app, there is only one packages
        @assert length(packages) == 1
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
        print(julia_code_buffer, app_start_code)
    end

    print(julia_code_buffer, """
        empty!(LOAD_PATH)
        empty!(DEPOT_PATH)
        """)

    # finally, make julia output the resulting object file
    @debug "creating object file at $object_file"
    @info "PackageCompiler: creating system image object file, this might take a while..."

    julia_code = String(take!(julia_code_buffer))
    outputo_file = tempname()
    write(outputo_file, julia_code)
    # Read the input via stdin to avoid hitting the maximum command line limit
    cmd = `$(get_julia_cmd()) --cpu-target=$cpu_target $sysimage_build_args
                              --sysimage=$base_sysimage --project=$project --output-o=$(object_file) $outputo_file`
    @debug "running $cmd"
    run(cmd)
    return
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
    for (_, pkg) in ctx.env.manifest
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
    create_sysimage(packages::Vector{String}; kwargs...)

Create a system image that includes the package(s) in `packages` given as a
string or vector).

An attempt to automatically find a compiler will be done but can also be given
explicitly by setting the environment variable `JULIA_CC` to a path to a
compiler (can also include extra arguments to the compiler, like `-g`).

### Keyword arguments:

- `sysimage_path::Union{String,Nothing}`: The path to where
  the resulting sysimage should be saved. If set to `nothing` the keyword argument
  `replace_default` needs to be set to `true`.

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

- `replace_default::Bool`: If `true`, replace the default system image which is automatically
  used when Julia starts. To replace with the one Julia ships with, use [`restore_default_sysimage()`](@ref)

- `include_transitive_dependencies::Bool`: If `true`, explicitly put all
   transitive dependencies into the sysimage. This only makes a differecnce if some
   packages do not load all their dependencies when themselves are loaded. Defaults to `true`.

### Advanced keyword arguments

- `base_sysimage::Union{Nothing, String}`: If a `String`, names an existing sysimage upon which to build
   the new sysimage incrementally, instead of the sysimage of the current process. Defaults to `nothing`.
   Keyword argument `incremental` must be `true` if `base_sysimage` is not `nothing`.

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image.

- `script::String`: Path to a file that gets executed in the `--output-o` process.

- `sysimage_build_args::Cmd`: A set of command line options that is used in the Julia process building the sysimage,
  for example `-O1 --check-bounds=yes`.
"""
function create_sysimage(packages::Union{Symbol, Vector{String}, Vector{Symbol}}=String[];
                         sysimage_path::Union{String,Nothing}=nothing,
                         project::String=dirname(active_project()),
                         precompile_execution_file::Union{String, Vector{String}}=String[],
                         precompile_statements_file::Union{String, Vector{String}}=String[],
                         incremental::Bool=true,
                         filter_stdlibs=false,
                         replace_default::Bool=false,
                         cpu_target::String=NATIVE_CPU_TARGET,
                         script::Union{Nothing, String}=nothing,
                         sysimage_build_args::Cmd=``,
                         include_transitive_dependencies::Bool=true,
                         # Internal args
                         base_sysimage::Union{Nothing, String}=nothing,
                         isapp::Bool=false,
                         julia_init_c_file=nothing,
                         version=nothing,
                         compat_level::String="major",
                         soname=nothing)
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
    Pkg.instantiate(ctx, verbose=true, allow_autoprecomp = false)
  

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
        base_sysimage = create_fresh_base_sysimage(sysimage_stdlibs; cpu_target)
    else
        if isnothing(base_sysimage)
            base_sysimage = current_process_sysimage_path()
        end
    end

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

    o_init_file = julia_init_c_file === nothing ? nothing : compile_c_init_julia(julia_init_c_file, sysimage_path)

    # Create the sysimage
    object_file = tempname() * ".o"
    create_sysimg_object_file(object_file, packages, packages_sysimg;
                              project,
                              base_sysimage,
                              precompile_execution_file,
                              precompile_statements_file,
                              cpu_target,
                              script,
                              isapp,
                              sysimage_build_args)
    create_sysimg_from_object_file(object_file,
                                   sysimage_path;
                                   o_init_file,
                                   compat_level,
                                   version,
                                   soname)

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
    m = something(march(), ``)
    flags = Base.shell_split(cflags())

    o_init_file = splitext(julia_init_c_file)[1] * ".o"
    cmd = `-c -O2 -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) $TLS_SYNTAX $(bitflag()) $flags $m -o $o_init_file $julia_init_c_file`
    run_compiler(cmd)
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
    rpath_args = rpath_sysimage()

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

    o_files = [input_object]
    o_init_file !== nothing && push!(o_files, o_init_file)

    # Prevent compiler from stripping all symbols from the shared lib.
    if Sys.isapple()
        o_file_flags = `-Wl,-all_load $o_files`
    else
        o_file_flags = `-Wl,--whole-archive $o_files -Wl,--no-whole-archive`
    end
    extra = get_extra_linker_flags(version, compat_level, soname)
    m = something(march(), ``)
    cmd = `$(bitflag()) $m -shared -L$(julia_libdir()) -L$(julia_private_libdir()) -o $sysimage_path $o_file_flags -ljulia-internal -ljulia $extra`
    run_compiler(cmd)
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

- `app_name::String`: an alternative name for the compiled app. If not provided,
  the name of the package (as specified in `Project.toml`) is used.

- `precompile_execution_file::Union{String, Vector{String}}`: A file or list of
  files that contain code from which precompilation statements should be recorded.

- `precompile_statements_file::Union{String, Vector{String}}`: A file or list of
  files that contain precompilation statements that should be included in the sysimage
  for the app.

- `incremental::Bool`: If `true`, build the new sysimage on top of the sysimage
  of the current process otherwise build a new sysimage from scratch. Defaults to `false`.

- `filter_stdlibs::Bool`: If `true`, only include stdlibs that are in the project file.
  Defaults to `false`, only set to `true` if you know the potential pitfalls.

- `audit::Bool`: Warn about eventual relocatability problems with the app, defaults
  to `true`.

- `force::Bool`: Remove the folder `compiled_app` if it exists before creating the app.

- `include_lazy_artifacts::Bool`: if lazy artifacts should be included in the bundled artifacts,
  defaults to `true`.

- `include_transitive_dependencies::Bool`: If `true`, explicitly put all
  transitive dependencies into the sysimage. This only makes a differecnce if some
  packages do not load all their dependencies when themselves are loaded. Defaults to `true`.

### Advanced keyword arguments

- `cpu_target::String`: The value to use for `JULIA_CPU_TARGET` when building the system image.

- `sysimage_build_args::Cmd`: A set of command line options that is used in the Julia process building the sysimage,
  for example `-O1 --check-bounds=yes`.
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
                    c_driver_program::String=String(DEFAULT_EMBEDDING_WRAPPER),
                    cpu_target::String=default_app_cpu_target(),
                    include_lazy_artifacts::Bool=true,
                    sysimage_build_args::Cmd=``,
                    include_transitive_dependencies::Bool=true)

    _create_app(package_dir, app_dir, app_name, precompile_execution_file,
        precompile_statements_file, incremental, filter_stdlibs, audit, force, cpu_target;
        library_only=false, c_driver_program, julia_init_c_file=nothing,
        header_files=String[], version=nothing, compat_level="major",
        include_lazy_artifacts, sysimage_build_args, include_transitive_dependencies)
end

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

- `audit::Bool`: Warn about eventual relocatability problems with the library, defaults
  to `true`.

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
  defaults to `true`.

- `include_transitive_dependencies::Bool`: If `true`, explicitly put all
  transitive dependencies into the sysimage. This only makes a differecnce if some
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
                        incremental=false,
                        filter_stdlibs=false,
                        audit=true,
                        force=false,
                        header_files::Vector{String} = String[],
                        julia_init_c_file::String=String(DEFAULT_JULIA_INIT),
                        version=nothing,
                        compat_level="major",
                        cpu_target::String=default_app_cpu_target(),
                        include_lazy_artifacts::Bool=true,
                        sysimage_build_args::Cmd=``,
                        include_transitive_dependencies::Bool=true)

    julia_init_h_file = String(DEFAULT_JULIA_INIT_HEADER)

    if !(julia_init_h_file in header_files)
        push!(header_files, julia_init_h_file)
    end

    if version isa String
        version = parse(VersionNumber, version)
    end

    _create_app(package_dir, dest_dir, lib_name, precompile_execution_file,
        precompile_statements_file, incremental, filter_stdlibs, audit, force, cpu_target;
        library_only=true, c_driver_program="", julia_init_c_file,
        header_files, version, compat_level, include_lazy_artifacts, sysimage_build_args, include_transitive_dependencies)

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
                    library_only::Bool,
                    c_driver_program::String,
                    julia_init_c_file,
                    header_files::Vector{String},
                    version,
                    compat_level::String,
                    include_lazy_artifacts::Bool,
                    sysimage_build_args::Cmd,
                    include_transitive_dependencies::Bool)
    isapp = !library_only

    precompile_statements_file = abspath.(precompile_statements_file)
    precompile_execution_file = abspath.(precompile_execution_file)
    package_dir = abspath(package_dir)
    ctx = create_pkg_context(package_dir)
    Pkg.instantiate(ctx, verbose=true, allow_autoprecomp = false)
    if isempty(ctx.env.manifest)
        @warn "it is not recommended to create an app without a preexisting manifest"
    end
    if ctx.env.pkg === nothing
        error("expected package to have a `name`-entry")
    end
    project_name = ctx.env.pkg.name
    if name === nothing
        name = project_name
    end

    sysimg_file = get_sysimg_file(name; library_only, version)
    soname = get_soname(name;
                        library_only,
                        version,
                        compat_level)

    if isdir(dest_dir)
        if !force
            error("directory $(repr(dest_dir)) already exists, use `force=true` to overwrite (will completely",
                  " remove the directory)")
        end
        rm(dest_dir; force=true, recursive=true)
    end

    audit && audit_app(ctx)

    mkpath(dest_dir)

    bundle_julia_libraries(dest_dir)
    bundle_artifacts(ctx, dest_dir; include_lazy_artifacts=include_lazy_artifacts)
    isapp && bundle_julia_executable(dest_dir)
    # TODO: Should also bundle project and update load_path for library 
    isapp && bundle_project(ctx, dest_dir)

    library_only && bundle_headers(dest_dir, header_files)

    # TODO: Create in a temp dir and then move it into place?
    sysimage_path = if Sys.isunix()
        isapp ? joinpath(dest_dir, "lib", "julia") : joinpath(dest_dir, "lib")
    else
        joinpath(dest_dir, "bin")
    end
    mkpath(sysimage_path)
    cd(sysimage_path) do
        if !incremental
            tmp = mktempdir()
            # Use workaround at https://github.com/JuliaLang/julia/issues/34064#issuecomment-563950633
            # by first creating a normal "empty" sysimage and then use that to finally create the one
            # with the @ccallable function
            tmp_base_sysimage = joinpath(tmp, "tmp_sys.so")
            create_sysimage(String[]; sysimage_path=tmp_base_sysimage, project=package_dir,
                            incremental=false, filter_stdlibs, cpu_target)

            create_sysimage([project_name]; sysimage_path=sysimg_file, project=package_dir,
                            incremental=true,
                            precompile_execution_file,
                            precompile_statements_file,
                            cpu_target,
                            base_sysimage=tmp_base_sysimage,
                            isapp,
                            julia_init_c_file,
                            version,
                            soname,
                            sysimage_build_args,
                            include_transitive_dependencies)
        else
            create_sysimage([project_name]; sysimage_path=sysimg_file, project=package_dir,
                                         incremental, filter_stdlibs,
                                         precompile_execution_file,
                                         precompile_statements_file,
                                         cpu_target,
                                         isapp,
                                         julia_init_c_file,
                                         version,
                                         soname,
                                         sysimage_build_args,
                                         include_transitive_dependencies)
        end

        if Sys.isapple()
            cmd = `install_name_tool -id @rpath/$sysimg_file $sysimg_file`
            @debug "running $cmd"
            run(cmd)
        end

        if library_only && version !== nothing && Sys.isunix()
            compat_file = get_sysimg_file(name; library_only, version, compat_level)
            base_file = get_sysimg_file(name)
            @debug "creating symlinks for $compat_file and $base_file"
            symlink(sysimg_file, compat_file)
            symlink(sysimg_file, base_file)
        end
    end

    if !library_only
        executable_path = joinpath(dest_dir, "bin")
        mkpath(executable_path)
        cd(executable_path) do
            c_driver_program_path = abspath(c_driver_program)
            sysimage_path = Sys.iswindows() ? sysimg_file : joinpath("..", "lib", "julia", sysimg_file)
            create_executable_from_sysimg(; sysimage_path, executable_path=name,
                                         c_driver_program_path)
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
    m = something(march(), ``)
    cmd = `-DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) $TLS_SYNTAX $(bitflag()) $m -o $(executable_path) $(wrapper) $(sysimage_path) -O2 $(rpath_executable()) $flags`
    run_compiler(cmd)
    return nothing
end

# One of the main reason for bunlding the project file is
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

function bundle_artifacts(ctx, dest_dir; include_lazy_artifacts=true)
    @debug "bundling artifacts..."

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
   
    for pkg in pkgs
        pkg_source_path = source_path(ctx, pkg)
        pkg_source_path === nothing && continue
        # Check to see if this package has an (Julia)Artifacts.toml
        for f in Pkg.Artifacts.artifact_names
            artifacts_toml_path = joinpath(pkg_source_path, f)
            if isfile(artifacts_toml_path)
                @debug "bundling artifacts for $(pkg.name)"
                artifacts = Artifacts.select_downloadable_artifacts(artifacts_toml_path; platform, include_lazy=include_lazy_artifacts)
                for name in keys(artifacts)
                    @debug "  \"$name\""
                    artifact_path = Pkg.ensure_artifact_installed(name, artifacts[name], artifacts_toml_path; platform)
                    mkpath(artifact_app_path)
                    cp(artifact_path, joinpath(artifact_app_path, basename(artifact_path)))
                end
                break
            end
        end
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
