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

function create_object_file(package::Symbol, project::String=active_project(); 
                            precompile_file::Union{String, Nothing}=nothing)
    julia_code = """
        if !isdefined(Base, :uv_eventloop)
            Base.reinit_stdio()
        end
        Base.__init__(); 
        using $package
        """
    example = joinpath(@__DIR__, "..", "examples", "hello.jl")
    julia_code *= """
    include($(repr(example)))
        """
    if precompile_file !== nothing
        tracefile = run_precompilation_script(project, precompile_file)
        precompile_code = """
            # This @eval prevents symbols from being put into Main
            @eval Module() begin
                PrecompileStagingArea = Module()
                for (_pkgid, _mod) in Base.loaded_modules
                    if !(_pkgid.name in ("Main", "Core", "Base"))
                        eval(PrecompileStagingArea, :(const \$(Symbol(_mod)) = \$_mod))
                    end
                end
                precompile_statements = readlines($(repr(tracefile)))
                for statement in sort(precompile_statements)
                    # println(statement)
                    try
                        Base.include_string(PrecompileStagingArea, statement)
                    catch
                        # See #28808
                        @error "failed to execute \$statement"
                    end
                end
            end # module
            """
        julia_code *= precompile_code
    end
    run(`$(get_julia_cmd()) --project=$project --output-o=sys.o -e $julia_code`)
end

function create_shared_library(input_object::String, output_library::String)
    julia_libdir = dirname(Libdl.dlpath("libjulia"))

    # Prevent compiler from stripping all symbols from the shared lib.
    # TODO: On clang on windows this is called something else
    if Sys.isapple()
        o_file = `-Wl,-all_load $input_object`
    else
        o_file = `-Wl,--whole-archive $input_object -Wl,--no-whole-archive`
    end
    run(`$CC -v -shared -L$(julia_libdir) -o $output_library $o_file -ljulia`)
end

function create_executable()
    flags = join((cflags(), ldflags(), ldlibs()), " ")
    flags = Base.shell_split(flags)
    wrapper = joinpath(@__DIR__, "embedding_wrapper.c")
     if Sys.iswindows()
        # functionality doesn't readily exist on this platform
    elseif Sys.isapple()
        rpath = `-Wl,-rpath,@executable_path`
    else
        rpath = `-Wl,-rpath,\$ORIGIN`
    end
    sysimg = "sys." * Libdl.dlext
    run(`$CC -DJULIAC_PROGRAM_LIBNAME=$(repr(sysimg)) -o myapp $(wrapper) $sysimg -O2 $rpath $flags`)
end

end # module
