using PackageCompiler
using Base.Test

# If this works without error we should be in pretty good shape!
# This command will use the runtest.jl of Matcha to find out what functions to precompile!
PackageCompiler.compile_package("Matcha", "UnicodeFun", force = false, reuse = false) # false to not force overwriting julia's current system image
# build again, with resuing the snoop file
img_file = PackageCompiler.compile_package("Matcha", "UnicodeFun", force = false, reuse = true)
# TODO test revert - I suppose i wouldn't have enough rights on travis to move around dll's?

@testset "basic tests" begin
    @test isfile(img_file)
    userimg = PackageCompiler.sysimg_folder("precompile.jl")
    @test isfile(userimg)
    # Make sure we actually snooped stuff
    @test length(readlines(userimg)) > 700
    @test success(`julia -J $(img_file)`)
    mktempdir() do dir
        sysfile = joinpath(dir, "sys")
        PackageCompiler.compile_system_image(sysfile, "native")
        @test isfile(sysfile * ".o")
        @test isfile(sysfile * ".$(Libdl.dlext)")
    end
end


@testset "juliac" begin
    mktempdir() do build
        juliac = joinpath(@__DIR__, "..", "juliac.jl")
        jlfile = joinpath(@__DIR__, "..", "examples", "hello.jl")
        cfile = joinpath(@__DIR__, "..", "examples", "program.c")
        julia = Base.julia_cmd()
        @test success(`$julia $juliac -vosej $jlfile $cfile $build`)
        @test isfile(joinpath(build, "hello.$(Libdl.dlext)"))
        @test isfile(joinpath(build, "hello$(executable_ext())"))
        cd(build) do
            @test success(`./$("hello$(executable_ext())")`)
        end
    end
end

@testset "build_executable" begin
    build = mktempdir()
    jlfile = joinpath(@__DIR__, "..", "examples", "hello.jl")
    snoopfile = open(joinpath(build, "snoop.jl"), "w") do io
        write(io, open(read, jlfile))
        println(io)
        println(io, "using .Hello; Hello.julia_main(String[])")
    end
    build_executable(
        jlfile,
        snoopfile = snoopfile, builddir = build,
        verbose = false, quiet = false,
    )
    @test isfile(joinpath(build, "hello.$(Libdl.dlext)"))
    @test isfile(joinpath(build, "hello$(executable_ext())"))
    cd(build) do
        @test success(`./$("hello$(executable_ext())")`)
    end
    for i = 1:100
        try rm(build, recursive = true) end
        sleep(1/100)
    end
end

using PackageCompiler
using Base.Test

@testset "shared library + executable" begin
    libdir = mktempdir()
    s_file, h_file = PackageCompiler.compile_sharedlib(libdir, :UnicodeFun)
    cprog = joinpath(libdir, "test.c")
    e_file = joinpath(libdir, "build", "test.exe")
    open(cprog, "w") do io
        println(io, """
        #include \"$(escape_string(h_file))\"
        int main(int argc, char *argv[]){
            intptr_t v;
            // Initialize Julia
            uv_setup_args(argc, argv); // no-op on Windows
            libsupport_init();
            jl_options.image_file = \"$(escape_string(s_file))\";
            julia_init(JL_IMAGE_JULIA_HOME);
            // Do some work
            int test = to_latex(\\itA \\in \\bbR^{nxn}, \\bfv \\in \\bbR^n, \\lambda_i \\in \\bbR: \\itA\\bfv = \\lambda_i\\bfv");
            printf(\"subscript of 4: %c \\n\", test);
            // Cleanup and graceful exit
            jl_atexit_hook(0);
            return 0;
        }
        """)
    end
    PackageCompiler.build_executable(s_file, e_file, cprog, true)
    @test success(`test.exe`)
    for i = 1:100
        # hm, why is this still needed on windows? Still the rm bug, or is
        # @test success(`test`) actually taking quite a bit of time to free the resource?
        try
            rm(libdir, recursive = true)
        end
        sleep(1/100)
    end
end
libdir = joinpath(homedir(), "UnicodeFun")
s_file, h_file = PackageCompiler.compile_sharedlib(libdir, :UnicodeFun)
write(STDOUT, open(read, h_file))
cprog = joinpath(libdir, "test.c")
e_file = joinpath(libdir, "build", "test.exe")
cprog = joinpath(libdir, "test.c")
e_file = joinpath(libdir, "build", "test.exe")
s_file = joinpath(libdir, "build", "unicodefun.dll")
PackageCompiler.build_executable(s_file, e_file, cprog, true)
success(`.\\$(e_file)`)
