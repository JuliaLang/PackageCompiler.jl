module PackageCompilerX

using Libdl

include("juliaconfig.jl")

function create_object(package::Symbol, project=Base.active_project(); precompilefile="precompile.jl")
    example = joinpath(@__DIR__, "..", "examples", "hello.jl")
    julia_code = """Base.__init__(); using $package; include("$(example)")"""
    julia_path = joinpath(Sys.BINDIR, Base.julia_exename())
    image_file = unsafe_string(Base.JLOptions().image_file)

    cmd = `$julia_path -J$image_file --color=yes --project=$project --output-o=sys.o --startup-file=no  -e $julia_code`
    run(cmd)
end

function create_shared_library(input_object::String, output_library::String)
    julia_libdir = dirname(Libdl.dlpath("libjulia"))

    # Prevent compiler from stripping all symbols from the shared lib.
    if Sys.isapple()
        o_file = `-Wl,-all_load $input_object`
    else
        o_file = `-Wl,--whole-archive $input_object -Wl,--no-whole-archive`
    end
    
    run(`clang -v -shared -L$(julia_libdir) -o $output_library $o_file -ljulia`)
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
    run(`clang -DJULIAC_PROGRAM_LIBNAME=\"$sysimg\" -o myapp $(wrapper) $sysimg -O2 $rpath $flags`)
end

end # module
