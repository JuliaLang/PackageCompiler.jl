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
function build_sysimg(
        sysimg_path, userimg_path = nothing;
        verbose = false, quiet = false,
        precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing
    )
    # build vanilla backup system image
    clean_sysimg = get_backup!(contains(basename(Base.julia_cmd().exec[1]), "debug"), cpu_target)
    return static_julia(
        userimg_path, verbose = verbose, quiet = quiet,
        builddir = sysimg_path, outname = "sys",
        autodeps = true, shared = true,
        sysimage = clean_sysimg, precompiled = precompiled, compilecache = compilecache,
        home = home, startup_file = startup_file, handle_signals = handle_signals,
        compile = compile, cpu_target = cpu_target, optimize = optimize, debug = debug,
        inline = inline, check_bounds = check_bounds, math_mode = math_mode, depwarn = depwarn
    )
end

function build_shared_lib(
        library, library_name;
        verbose = false, quiet = false,
        sysimage = nothing, precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing
    )
    return static_julia(
        library, verbose = verbose, quiet = quiet,
        builddir = sysimg_path, outname = library_name,
        autodeps = true, shared = true, julialibs = true,
        sysimage = sysimage, precompiled = precompiled, compilecache = compilecache,
        home = home, startup_file = startup_file, handle_signals = handle_signals,
        compile = compile, cpu_target = cpu_target, optimize = optimize, debug = debug,
        inline = inline, check_bounds = check_bounds, math_mode = math_mode, depwarn = depwarn
    )
end

"""
    build_executable(
        library,
        library_name = splitext(basename(library))[1],
        cprog = joinpath(@__DIR__, "..", "examples", "program.c");
        snoopfile = nothing, builddir = "builddir",
        verbose = false, quiet = false,
        cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing
    )
    `library` needs to be a julia file containing a julia main, e.g. like examples/hello.jl
    `snoopfile` is optional and can be julia file that calls functions that you want to make sure to have precompiled
    `builddir` is where library_name.exe and shared libraries will end up
"""
function build_executable(
        library, library_name = splitext(basename(library))[1],
        cprog = joinpath(@__DIR__, "..", "examples", "program.c");
        snoopfile = nothing, builddir = "builddir",
        verbose = false, quiet = false,
        sysimage = nothing, precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing
    )
    if snoopfile != nothing
        precompfile = joinpath(builddir, "precompiled.jl")
        snoop(snoopfile, precompfile, joinpath(builddir, "snoop.csv"))
        jlmain = joinpath(builddir, "julia_main.jl")
        open(jlmain, "w") do io
            println(io, "include(\"$(escape_string(relpath(precompfile, builddir)))\")")
            println(io, "include(\"$(escape_string(relpath(library, builddir)))\")")
        end
        library = jlmain
    end
    return static_julia(
        library, cprog = cprog, verbose = verbose, quiet = quiet,
        builddir = builddir, outname = library_name,
        autodeps = true, executable = true, julialibs = true,
        sysimage = sysimage, precompiled = precompiled, compilecache = compilecache,
        home = home, startup_file = startup_file, handle_signals = handle_signals,
        compile = compile, cpu_target = cpu_target, optimize = optimize, debug = debug,
        inline = inline, check_bounds = check_bounds, math_mode = math_mode, depwarn = depwarn
    )
end

"""
    force_native_image!()
Builds a clean system image, similar to a fresh Julia install.
Can also be used to build a native system image for a downloaded cross compiled julia binary.
"""
function force_native_image!(debug = false) # debug is ignored right now
    sysimg = get_backup!(debug, "native")

    copy_system_image(dirname(sysimg), default_sysimg_path(debug))
end
