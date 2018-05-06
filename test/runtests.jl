using PackageCompiler
using Base.Test

# If this works without error we should be in pretty good shape!
# This command will use the runtest.jl of Matcha to find out what functions to precompile!
PackageCompiler.compile_package("Matcha", "UnicodeFun", force = false, reuse = false) # false to not force overwriting julia's current system image
# build again, with resuing the snoop file
img_file = PackageCompiler.compile_package("Matcha", "UnicodeFun", force = false, reuse = true)
# TODO test revert - I suppose i wouldn't have enough rights on travis to move around dll's?
julia = Base.julia_cmd().exec[1]
@testset "basic tests" begin
    @test isfile(img_file)
    userimg = PackageCompiler.sysimg_folder("precompile.jl")
    @test isfile(userimg)
    # Make sure we actually snooped stuff
    @test length(readlines(userimg)) > 700
    @test success(`$julia -J $(img_file)`)
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
        @test success(`$julia $juliac -vosej $jlfile $cfile --builddir $build`)
        @test isfile(joinpath(build, "hello.$(Libdl.dlext)"))
        @test isfile(joinpath(build, "hello$(executable_ext())"))
        cd(build) do
            @test success(`./$("hello$(executable_ext())")`)
        end
        @testset "--cc-flags" begin
            # Try passing `--help` to $cc. This should work for any system compiler.
            # Then grep the output for "-g", which should be present on any system.
            @test contains(readstring(`$julia $juliac -se --cc-flags='--help' $jlfile $cfile --builddir $build`), "-g")
            # Just as a control, make sure that without passing '--help', we don't see "-g"
            @test !contains(readstring(`$julia $juliac -se $jlfile $cfile --builddir $build`), "-g")
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
