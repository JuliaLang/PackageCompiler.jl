using PackageCompiler, Test

@testset "compilage_package" begin
    @testset "FixedPointNumbers" begin
        sysimage = PackageCompiler.compile_package("FixedPointNumbers", verbose = true)
        test_code = """
        using FixedPointNumbers; N0f8(0.5); println("no segfaults, yay")
        """
        cmd = PackageCompiler.julia_code_cmd(test_code, J = sysimage)
        @test read(cmd, String) == "no segfaults, yay\n"
    end
    @testset "FixedPointNumbers ColorTypes" begin
        sysimage = PackageCompiler.compile_package("FixedPointNumbers", "ColorTypes", verbose = true)
        test_code = """
        using FixedPointNumbers, ColorTypes; N0f8(0.5); RGB(0.0, 0.0, 0.0); println("no segfaults, yay")
        """
        cmd = PackageCompiler.julia_code_cmd(test_code, J = sysimage)
        @test read(cmd, String) == "no segfaults, yay\n"
    end
end


@testset "compile_incremental" begin
    @testset "unregistered package with runtests.jl" begin
        path = joinpath(@__DIR__, "TestPackage")
        push!(Base.LOAD_PATH, path)
        syso, syso_old = PackageCompiler.compile_incremental(:TestPackage)
        test_code = """
        push!(Base.LOAD_PATH, $(repr(path)))
        using TestPackage; TestPackage.greet()
        """
        cmd = PackageCompiler.julia_code_cmd(test_code, J = syso)
        @test read(cmd, String) == "Hello World!"
        pop!(Base.LOAD_PATH)
    end
    @testset "unregistered package with snoopfile.jl" begin
        path = joinpath(@__DIR__, "TestPackage2")
        push!(Base.LOAD_PATH, path)
        syso, syso_old = PackageCompiler.compile_incremental(:TestPackage2)
        test_code = """
        push!(Base.LOAD_PATH, $(repr(path)))
        using TestPackage2; TestPackage2.greet()
        """
        cmd = PackageCompiler.julia_code_cmd(test_code, J = syso)
        @test read(cmd, String) == "Hello World!"
        pop!(Base.LOAD_PATH)
    end
    @testset "FixedPointNumbers" begin
        # This is the new compile_package
        syso, syso_old = PackageCompiler.compile_incremental(:FixedPointNumbers)
        test_code = """
        using FixedPointNumbers; N0f8(0.5); println("no segfaults, yay")
        """
        cmd = PackageCompiler.julia_code_cmd(test_code, J = syso)
        @test read(cmd, String) == "no segfaults, yay\n"
    end
    @testset "FixedPointNumbers ColorTypes" begin
        syso, syso_old = PackageCompiler.compile_incremental(:FixedPointNumbers, :ColorTypes)
        test_code = """
        using FixedPointNumbers, ColorTypes; N0f8(0.5); RGB(0.0, 0.0, 0.0); println("no segfaults, yay")
        """
        cmd = PackageCompiler.julia_code_cmd(test_code, J = syso)
        @test read(cmd, String) == "no segfaults, yay\n"
    end
    @testset "JSON with Distributed blacklisted" begin
        # This is the new compile_package
        syso, syso_old = PackageCompiler.compile_incremental(:JSON, blacklist=[:Distributed])
        test_code = """
        using JSON 
        s = \"{\\"a_number\\" : 5.0, \\"an_array\\" : [\\"string\\", 9]}\"
        j = JSON.parse(s)
        println(\"no segfaults, yay\")
        """
        cmd = PackageCompiler.julia_code_cmd(test_code, J = syso)
        @test read(cmd, String) == "no segfaults, yay\n"
    end
end

julia = Base.julia_cmd().exec[1]

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
        build_executable(
            jlfile, snoopfile = snoopfile, builddir = relativebuilddir, verbose = true
        )
    end
    builddir = joinpath(basedir, relativebuilddir)
    @test isfile(joinpath(builddir, "hello.$(PackageCompiler.Libdl.dlext)"))
    @test isfile(joinpath(builddir, "hello$executable_ext"))
    @test startswith(read(`$(joinpath(builddir, "hello$executable_ext"))`, String), "hello, world")
    for i = 1:100
        # Windows seems to have problems with removing files - it can error
        # making this test fail.
        try rm(basedir, recursive = true) catch end
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
        output = read(`$exe a b c`, String)
        println(output)
        @test output ==
            "@__FILE__: $argsjlfile\n" *
            "PROGRAM_FILE: $exe\n" *
            "argv: [\"a\", \"b\", \"c\"]\n" *
            "ARGS: [\"a\", \"b\", \"c\"]\n" *
            "Base.ARGS: [\"a\", \"b\", \"c\"]\n" *
            "Core.ARGS: Any[\"$(Sys.iswindows() ? replace(exe, "\\" => "\\\\") : exe)\", \"a\", \"b\", \"c\"]\n"
    end
end

@testset "juliac" begin
    mktempdir() do builddir
        juliac = joinpath(@__DIR__, "..", "juliac.jl")
        jlfile = joinpath(@__DIR__, "..", "examples", "hello.jl")
        cfile = joinpath(@__DIR__, "..", "examples", "program.c")
        @test success(`$julia $juliac -vaej $jlfile $cfile --builddir $builddir`)
        @test isfile(joinpath(builddir, "hello.$(PackageCompiler.Libdl.dlext)"))
        @test isfile(joinpath(builddir, "hello$executable_ext"))
        @test success(`$(joinpath(builddir, "hello$executable_ext"))`)
        @testset "--cc-flag" begin
            # Try passing `--help` to $cc. This should work for any system compiler.
            # Then grep the output for "-g", which should be present on any system.
            @test occursin("-g", read(`$julia $juliac -se --cc-flag="--help" $jlfile $cfile --builddir $builddir`, String))
            # Just as a control, make sure that without passing '--help', we don't see "-g"
            @test !occursin("-g", read(`$julia $juliac -se $jlfile $cfile --builddir $builddir`, String))
        end
    end
end
