# This file is taken from Julia right now, since I had to modify it a bit

#=
Copyright (c) 2009-2016: Jeff Bezanson, Stefan Karpinski, Viral B. Shah, and other contributors:
https://github.com/JuliaLang/julia/contributors
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
=#

#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

# Build a system image binary at sysimg_path.dlext. Allow insertion of a userimg via
# userimg_path.  If sysimg_path.dlext is currently loaded into memory, don't continue
# unless force is set to true.  Allow targeting of a CPU architecture via cpu_target.
const depsfile = joinpath(@__DIR__, "..", "deps", "deps.jl")

if isfile(depsfile)
    include(depsfile)
    gccworks = try
        success(`$gcc -v`)
    catch
        false
    end
    if !gccworks
        error("GCC wasn't found. Please make sure that gcc is on the path and run Pkg.build(\"PackageCompiler\")")
    end
else
    error("Package wasn't build correctly. Please run Pkg.build(\"PackageCompiler\")")
end

system_compiler() = gcc

function default_sysimg_path(debug = false)
    ext = debug ? "sys-debug" : "sys"
    if is_unix()
        dirname(splitext(Libdl.dlpath(ext))[1])
    else
        joinpath(dirname(JULIA_HOME), "lib", "julia")
    end
end

"""
    build_sysimg(sysimg_path=default_sysimg_path(), cpu_target="native", userimg_path=nothing; force=false)

Rebuild the system image. Store it in `sysimg_path`, which defaults to a file named `sys.ji`
that sits in the same folder as `libjulia.{so,dylib}`, except on Windows where it defaults
to `JULIA_HOME/../lib/julia/sys.ji`.  Use the cpu instruction set given by `cpu_target`.
Valid CPU targets are the same as for the `-C` option to `julia`, or the `-march` option to
`gcc`.  Defaults to `native`, which means to use all CPU instructions available on the
current processor. Include the user image file given by `userimg_path`, which should contain
directives such as `using MyPackage` to include that package in the new system image. New
system image will not replace an older image unless `force` is set to true.
"""
function build_sysimg(sysimg_path, cpu_target, userimg_path = nothing; debug = false)
    # Enter base and setup some useful paths
    base_dir = dirname(Base.find_source_file("sysimg.jl"))
    cd(base_dir) do
        julia = joinpath(JULIA_HOME, debug ? "julia-debug" : "julia")
        cc = system_compiler()
        # Ensure we have write-permissions to wherever we're trying to write to
        try
            touch("$sysimg_path.ji")
        catch
            err_msg =  "Unable to modify $sysimg_path.ji, ensure parent directory exists "
            err_msg *= "and is writable; absolute paths work best.)"
            error(err_msg)
        end

        # Copy in userimg.jl if it exists
        if userimg_path != nothing
            if !isfile(userimg_path)
                error("$userimg_path is not found, ensure it is an absolute path.")
            end
            if isfile("userimg.jl")
                error("$base_dir/userimg.jl already exists, delete manually to continue.")
            end
            cp(userimg_path, "userimg.jl")
        end
        try
            # Start by building inference.{ji,o}
            inference_path = joinpath(dirname(sysimg_path), "inference")
            info("Building inference.o")
            info("$julia -C $cpu_target --output-ji $inference_path.ji --output-o $inference_path.o coreimg.jl")
            run(`$julia -C $cpu_target --output-ji $inference_path.ji --output-o $inference_path.o coreimg.jl`)

            # Bootstrap off of that to create sys.{ji,o}
            info("Building sys.o")
            info("$julia -C $cpu_target --output-ji $sysimg_path.ji --output-o $sysimg_path.o -J $inference_path.ji --startup-file=no sysimg.jl")
            run(`$julia -C $cpu_target --output-ji $sysimg_path.ji --output-o $sysimg_path.o -J $inference_path.ji --startup-file=no sysimg.jl`)

            link_sysimg(sysimg_path, cc, debug)

        finally
            # Cleanup userimg.jl
            if isfile("userimg.jl")
                rm("userimg.jl")
            end
        end
    end
end

# Link sys.o into sys.$(dlext)
function link_sysimg(sysimg_path, cc = system_compiler(), debug = false)

    julia_libdir = dirname(Libdl.dlpath(debug ? "libjulia-debug" : "libjulia"))

    FLAGS = ["-L$julia_libdir"]

    push!(FLAGS, "-shared")
    push!(FLAGS, debug ? "-ljulia-debug" : "-ljulia")
    if is_windows()
        push!(FLAGS, "-lssp")
    end

    sysimg_file = "$sysimg_path.$(Libdl.dlext)"
    info("Linking sys.$(Libdl.dlext)")
    info("$cc $(join(FLAGS, ' ')) -o $sysimg_file $sysimg_path.o")
    # Windows has difficulties overwriting a file in use so we first link to a temp file
    run(`$cc $FLAGS -o $sysimg_file $sysimg_path.o`)
end
