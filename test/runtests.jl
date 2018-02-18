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
        build = mktempdir()
        julia = Base.julia_cmd()
        @test success(`$julia $juliac -vosej $jlfile $cfile $build`)
        @test isfile(joinpath(build, "hello.$(Libdl.dlext)"))
        @test isfile(joinpath(build, "hello$(executable_ext())"))
        cd(build) do
            run(`./$("hello$(executable_ext())")`)
        end
    end
end
