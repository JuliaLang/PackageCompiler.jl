function verify_gcc(gcc)
    try # success errors when not successful :(
        return success(`$gcc --version`)
    catch
        return false
    end
    return false
end

# TODO: remove once Julia v0.7 is released
const julia_v07 = VERSION > v"0.7-"
if julia_v07
    const isunix = Sys.isunix
    const iswindows = Sys.iswindows
else
    const isunix = is_unix
    const iswindows = is_windows
end

if iswindows()
    using WinRPM
end

function build()
    gccpath = ""
    if isfile("deps.jl")
        include("deps.jl")
        if verify_gcc(gcc)
            @info("gcc already installed and package already build")
            return
        else
            rm("deps.jl")
        end
    end

    if haskey(ENV, "CC")
        if !verify_gcc(`$(ENV["CC"]) -v`)
            error("Using compiler override from environment variable CC = $(ENV["CC"]), but unable to run `$(ENV["CC"]) -v`.")
        end
        gccpath = ENV["CC"]
        @info("using $gccpath as a compiler from environment variable CC")
    end

    @info("installing gcc")

    if verify_gcc("cc")
        gccpath = "cc"
        @info("using cc as a compiler")
    elseif iswindows()
        gccpath = joinpath(
            WinRPM.installdir, "usr", "$(Sys.ARCH)-w64-mingw32",
            "sys-root", "mingw", "bin", "gcc.exe"
        )
        if !isfile(gccpath)
            WinRPM.install("gcc", yes = true)
        end
        if !isfile(gccpath)
            error("Couldn't install gcc via winrpm")
        end
        @info("using gcc from WinRPM as a compiler")
    elseif isunix() && verify_gcc("gcc")
        gccpath = "gcc"
        @info("using gcc as a compiler")
    end

    if isempty(gccpath)
        error("Please make sure to provide a working gcc in your path!")
    end
    open("deps.jl", "w") do io
        print(io, "const gcc = ")
        println(io, '"', escape_string(gccpath), '"')
    end
end

build()
