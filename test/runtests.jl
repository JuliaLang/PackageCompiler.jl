using PackageCompilerX
using Test
using Libdl

@testset "PackageCompilerX.jl" begin
    # Write your own tests here.
    PackageCompilerX.create_object(:Example)
    sysimg = "sys." * Libdl.dlext
    PackageCompilerX.create_shared_library("sys.o", sysimg)
    run(`$(Base.julia_cmd()) -J $(sysimg) -e 'println(1337)'`)
    PackageCompilerX.create_executable()
    output = read(`./myapp`, String)
    @test occursin("hello, world", output)
end
