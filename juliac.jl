## Assumptions:
## 1. g++ / x86_64-w64-mingw32-gcc is available and is in path

function compile(julia_program_file, julia_install_path,
                 julia_pkgdir=joinpath(Pkg.dir(), ".."))
    filename = split(julia_program_file, ".")[1]
    O_FILE = "$(filename).o"

    SYS_LIB = joinpath(julia_install_path, "lib", "julia", "sys.so")
    JULIA_EXE = joinpath(julia_install_path, "bin", "julia")
    LIB_PATH = joinpath(julia_install_path, "lib")
    SO_FILE = "lib$(filename).$(Libdl.dlext)"
    if is_windows()
        julia_pkgdir = replace(julia_pkgdir, "\\", "\\\\")
        julia_program_file = replace(julia_program_file, "\\", "\\\\")
    end

    run(`"$(Base.julia_cmd())" "-J$(SYS_LIB)" "--startup-file=no" "--output-o" "$(O_FILE)" "-e" "
         vers = \""v$(VERSION.major).$(VERSION.minor)"\"
         const DIR_NAME = \"".julia"\"
         push!(Base.LOAD_CACHE_PATH, abspath(\""$julia_pkgdir"\", \""lib"\", vers))
         include(\""$(julia_program_file)"\")
         empty!(Base.LOAD_CACHE_PATH)
         "`)

    cflags = Base.shell_split(readstring(`$(JULIA_EXE) $(joinpath(julia_install_path, "share", "julia", "julia-config.jl")) --cflags`))
    ldflags = Base.shell_split(readstring(`$(JULIA_EXE) $(joinpath(julia_install_path, "share", "julia", "julia-config.jl")) --ldflags`))
    ldlibs = Base.shell_split(readstring(`$(JULIA_EXE) $(joinpath(julia_install_path, "share", "julia", "julia-config.jl")) --ldlibs`))

    if is_windows()
        run(`x86_64-w64-mingw32-gcc -m64 -fPIC -shared -o $(SO_FILE) $(O_FILE) $(ldflags) $(ldlibs)`)
        run(`x86_64-w64-mingw32-gcc -m64 program.c -o $(filename).exe $(SO_FILE) $(cflags) $(ldflags) $(ldlibs) -lopenlibm -Wl,-rpath,\$ORIGIN`)
    else
        run(`g++ -m64 -fPIC -shared -o $(SO_FILE) $(O_FILE) $(ldflags) $(ldlibs)`)
        run(`gcc -m64 program.c -o $(filename) $(SO_FILE) $(cflags) $(ldflags) $(ldlibs) -lm -Wl,-rpath,\$ORIGIN`)
    end
end


if length(ARGS) < 2
    println("Usage: $(@__FILE__) <Julia Program file> <Julia installation Path> [Julia Package Directory]")
    exit(1)
end
JULIA_PROGRAM_FILE = ARGS[1]
JULIA_INSTALL_PATH = ARGS[2]

println("Program File : $JULIA_PROGRAM_FILE")
println("Julia Install Path: $JULIA_INSTALL_PATH")

if length(ARGS) > 2
    return compile(JULIA_PROGRAM_FILE, JULIA_INSTALL_PATH, ARGS[3])
else
    return compile(JULIA_PROGRAM_FILE, JULIA_INSTALL_PATH)
end
