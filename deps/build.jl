function verify_gcc(gcc)
    try
        return success(`$gcc --version`)
    end
    return false
end

gccpath = ""

if isfile("deps.jl")
    include("deps.jl")
    if verify_gcc(gcc)
        info("gcc already installed")
        return
    else
        rm("deps.jl")
    end
end
info("installing gcc")
if is_windows()
    using WinRPM
    gccpath = joinpath(
        WinRPM.installdir, "usr", "$(Sys.ARCH)-w64-mingw32",
        "sys-root", "mingw", "bin", "gcc.exe"
    )
    if !isfile(gccpath)
        WinRPM.install("gcc")
    end
    if !isfile(gccpath)
        error("Couldn't install gcc via winrpm")
    end
end

if is_unix()
    if verify_gcc("gcc")
        gccpath = "gcc"
    end
end
if isempty(gccpath)
    error("Please make sure to provide a working gcc in your path!")
end

open("deps.jl", "w") do io
    print(io, "const gcc = ")
    println(io, '"', escape_string(gccpath), '"')
end
