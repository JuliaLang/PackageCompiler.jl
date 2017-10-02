## Assumptions:
## 1. g++ / x86_64-w64-mingw32-gcc is available and is in path

function compile(julia_program_file)
    filename = split(julia_program_file, ".")[1]
    O_FILE = "$(filename).o"
    SO_FILE = "lib$(filename).$(Libdl.dlext)"

    julia_pkglibdir = joinpath(dirname(Pkg.dir()), "lib", basename(Pkg.dir()))

    if is_windows()
        julia_program_file = replace(julia_program_file, "\\", "\\\\")
        julia_pkglibdir = replace(julia_pkglibdir, "\\", "\\\\")
    end

    run(`"$(Base.julia_cmd())" "--startup-file=no" "--output-o" "$(O_FILE)" "-e" "
         include(\"$(julia_program_file)\")
         push!(Base.LOAD_CACHE_PATH, \"$julia_pkglibdir\")
         empty!(Base.LOAD_CACHE_PATH)
         "`)

    cflags = Base.shell_split(readstring(`$(Base.julia_cmd()) $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl")) --cflags`))
    ldflags = Base.shell_split(readstring(`$(Base.julia_cmd()) $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl")) --ldflags`))
    ldlibs = Base.shell_split(readstring(`$(Base.julia_cmd()) $(joinpath(dirname(JULIA_HOME), "share", "julia", "julia-config.jl")) --ldlibs`))

    if is_windows()
        run(`x86_64-w64-mingw32-gcc -m64 -fPIC -shared -o $(SO_FILE) $(O_FILE) $(ldflags) $(ldlibs) -Wl,--export-all-symbols`)
        run(`x86_64-w64-mingw32-gcc -m64 program.c -o $(filename).exe $(SO_FILE) $(cflags) $(ldflags) $(ldlibs) -lopenlibm -Wl,-rpath,\$ORIGIN`)
    else
        run(`g++ -m64 -fPIC -shared -o $(SO_FILE) $(O_FILE) $(ldflags) $(ldlibs)`)
        run(`gcc -m64 program.c -o $(filename) $(SO_FILE) $(cflags) $(ldflags) $(ldlibs) -lm -Wl,-rpath,\$ORIGIN`)
    end
end


if length(ARGS) != 1
    println("Usage: $(@__FILE__) <Julia Program file>")
    exit(1)
end

JULIA_PROGRAM_FILE = ARGS[1]

println("Program File : $JULIA_PROGRAM_FILE")

compile(JULIA_PROGRAM_FILE)

