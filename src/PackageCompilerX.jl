module PackageCompilerX

using Base: active_project
using Libdl

include("juliaconfig.jl")

const CC = `gcc`

function get_julia_cmd()
    julia_path = joinpath(Sys.BINDIR, Base.julia_exename())
    image_file = unsafe_string(Base.JLOptions().image_file)
    cmd = `$julia_path -J$image_file --color=yes --startup-file=no`
end

# Returns a vector of precompile statemenets
function run_precompilation_script(project::String, precompile_file::String)
    tracefile = tempname()
    julia_code = """Base.__init__(); include($(repr(precompile_file)))"""
    run(`$(get_julia_cmd()) --project=$project --trace-compile=$tracefile -e $julia_code`)
    return tracefile
end

function create_object_file(object_file::String, packages::Union{Symbol, Vector{Symbol}}, project::String=active_project(); 
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

    # include the "App file" containing julia_main
    example = joinpath(@__DIR__, "..", "examples", "hello.jl")
    julia_code *= """
        include($(repr(example)))
        """
    
    # handle precompilation
    if precompile_execution_file !== nothing || precompile_statements_file !== nothing
        precompile_statements = ""
        if precompile_execution_file !== nothing
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
    run(`$(get_julia_cmd()) --project=$project --output-o=$(object_file) -e $julia_code`)
end

default_sysimage_path() = joinpath(julia_private_libdir(), "sys." * Libdl.dlext)
backup_sysimage_path() = default_sysimage_path() * ".backup"

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
    create_object_file(object_file, packages, project; precompile_execution_file=precompile_execution_file,
                       precompile_statements_file=precompile_statements_file)
    @show sysimage_path
    create_sysimage_from_object_file(object_file, sysimage_path)
    if replace_default_sysimage
        if !isfile(backup_sysimage_path())
            cp(default_sysimage_path(), backup_sysimage_path())
            @debug "making a backup of sysimage"
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
    run(`$CC -v -shared -L$(julia_libdir) -o $sysimage_path $o_file -ljulia`)
    return nothing
end

function restore_default_sysimage()
    if !isfile(backup_sysimage_path())
        error("did not find a backup sysimage")
    end
    cp(backup_sysimage_path(), default_sysimage_path(); force=true)
    rm(backup_sysimage_path())
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
        # Cannot create an executable without copying dlls on Windows...
        rpath = `` # functionality doesn't readily exist on this platform
    elseif Sys.isapple()
        rpath = `-Wl,-rpath,@executable_path`
    else
        rpath = `-Wl,-rpath,\$ORIGIN`
    end
    run(`$CC -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimage_path)) -o $(executable_path) $(wrapper) $sysimage_path -O2 $rpath $flags`)
    return nothing
end

end # module
