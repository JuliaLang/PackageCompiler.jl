using PackageCompiler
using Base.Test

# If this works without error we should be in pretty good shape!
# This command will use the runtest.jl of Matcha to find out what functions to precompile!
compile_package("Matcha", "UnicodeFun", force = false, reuse = false) # false to not force overwriting julia's current system image
# build again, with resuing the snoop file
img_file = compile_package("Matcha", "UnicodeFun", force = false, reuse = true)
# TODO test revert - I suppose i wouldn't have enough rights on travis to move around dll's?
julia = Base.julia_cmd().exec[1]
@testset "basic tests" begin
    @test isfile(img_file)
    userimg = PackageCompiler.sysimg_folder("precompile.jl")
    @test isfile(userimg)
    # Make sure we actually snooped stuff
    @test length(readlines(userimg)) > 700
    @test success(`$julia -J $img_file`)
    mktempdir() do dir
        sysfile = joinpath(dir, "sys")
        PackageCompiler.compile_system_image(sysfile, "native")
        @test isfile(sysfile * ".o")
        @test isfile(sysfile * ".$(Libdl.dlext)")
    end
end

@testset "build_executable" begin
    jlfile = joinpath(@__DIR__, "..", "examples", "hello.jl")
    basedir = mktempdir()
    relativebuilddir = "build"
    cd(basedir) do
        mkdir(relativebuilddir)
        snoopfile = "snoop.jl"
        open(snoopfile, "w") do io
            write(io, open(read, jlfile))
            println(io)
            println(io, "using .Hello; Hello.julia_main(String[])")
        end
        @test build_executable(
            jlfile, snoopfile = snoopfile, builddir = relativebuilddir, verbose = true
        )
    end
    builddir = joinpath(basedir, relativebuilddir)
    @test isfile(joinpath(builddir, "hello.$(Libdl.dlext)"))
    @test isfile(joinpath(builddir, "hello$executable_ext"))
    @test success(`$(joinpath(builddir, "hello$executable_ext"))`)
    for i = 1:100
        try rm(basedir, recursive = true) end
        sleep(1/100)
    end
end

@testset "program.c" begin
    @testset "args" begin
        basedir = mktempdir();
        argsjlfile = mktemp(basedir)[1];
        write(argsjlfile, raw"""
            Base.@ccallable function julia_main(argv::Vector{String})::Cint
                println("@__FILE__: $(@__FILE__)")
                println("PROGRAM_FILE: $(PROGRAM_FILE)")
                println("argv: $(argv)")
                # Sometimes code accesses ARGS directly, as a global
                println("ARGS: $ARGS")
                println("Base.ARGS: $(Base.ARGS)")
                println("Core.ARGS: $(Core.ARGS)")
                return 0
            end
        """)
        builddir = joinpath(basedir, "builddir")
        outname = "args"
        build_executable(
            argsjlfile, outname; builddir = builddir
        )
        # Check that the output from the program is as expected:
        exe = joinpath(builddir, outname*executable_ext)
        output = readstring(`$exe a b c`)
        println(output)
        @test all(s->contains(output, s), [
                "@__FILE__: " * argsjlfile
                "PROGRAM_FILE: " * exe
                """argv: String["a", "b", "c"]"""
                """ARGS: String["a", "b", "c"]"""
                """Base.ARGS: String["a", "b", "c"]"""
                # This one is a regex because it's difficult to correctly match
                # both the unix and windows outputs.
                r"Core.ARGS: .*[\".*builddir.*outname.*\", \"a\", \"b\", \"c\"]"
            ]
        )
    end
end

@testset "juliac" begin
    mktempdir() do builddir
        juliac = joinpath(@__DIR__, "..", "juliac.jl")
        jlfile = joinpath(@__DIR__, "..", "examples", "hello.jl")
        cfile = joinpath(@__DIR__, "..", "examples", "program.c")
        @test success(`$julia $juliac -vosej $jlfile $cfile --builddir $builddir`)
        @test isfile(joinpath(builddir, "hello.$(Libdl.dlext)"))
        @test isfile(joinpath(builddir, "hello$executable_ext"))
        @test success(`$(joinpath(builddir, "hello$executable_ext"))`)
        @testset "--cc-flags" begin
            # Try passing `--help` to $cc. This should work for any system compiler.
            # Then grep the output for "-g", which should be present on any system.
            @test contains(readstring(`$julia $juliac -se --cc-flags="--help" $jlfile $cfile --builddir $builddir`), "-g")
            # Just as a control, make sure that without passing '--help', we don't see "-g"
            @test !contains(readstring(`$julia $juliac -se $jlfile $cfile --builddir $builddir`), "-g")
        end
    end
end
