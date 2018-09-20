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
        verbose = false, quiet = false, release = false,
        precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing,
        cc = nothing, cc_flags = nothing
    )
    # build vanilla backup system image
    clean_sysimg = get_backup!(contains(basename(Base.julia_cmd().exec[1]), "debug"), cpu_target)
    static_julia(
        userimg_path, verbose = verbose, quiet = quiet,
        builddir = sysimg_path, outname = "sys",
        autodeps = true, shared = true, release = release,
        sysimage = clean_sysimg, precompiled = precompiled, compilecache = compilecache,
        home = home, startup_file = startup_file, handle_signals = handle_signals,
        compile = compile, cpu_target = cpu_target, optimize = optimize, debug = debug,
        inline = inline, check_bounds = check_bounds, math_mode = math_mode, depwarn = depwarn,
        cc = cc, cc_flags = cc_flags
    )
end

"""
    build_shared_lib(
        julia_program, output_name = nothing;
        snoopfile = nothing, builddir = nothing, verbose = false, quiet = false,
        copy_julialibs = true, copy_files = nothing, release = false, Release = false,
        sysimage = nothing, precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing,
        cc = nothing, cc_flags = nothing
    )
    `julia_program` needs to be a Julia script containing a `julia_main` function, e.g. like `examples/hello.jl`
    `snoopfile` is optional and can be a Julia script which calls functions that you want to make sure to have precompiled
    `builddir` is where the compiled artifacts will end up
"""
function build_shared_lib(
        julia_program, output_name = nothing;
        snoopfile = nothing, builddir = nothing, verbose = false, quiet = false,
        copy_julialibs = true, copy_files = nothing, release = false, Release = false,
        sysimage = nothing, precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing,
        cc = nothing, cc_flags = nothing, shared_init = false
    )
    static_julia(
        julia_program, verbose = verbose, quiet = quiet,
        builddir = builddir, outname = output_name, snoopfile = snoopfile, autodeps = true, shared = true,
        copy_julialibs = copy_julialibs, copy_files = copy_files, release = release, Release = release,
        sysimage = sysimage, precompiled = precompiled, compilecache = compilecache,
        home = home, startup_file = startup_file, handle_signals = handle_signals,
        compile = compile, cpu_target = cpu_target, optimize = optimize, debug = debug,
        inline = inline, check_bounds = check_bounds, math_mode = math_mode, depwarn = depwarn,
        cc = cc, cc_flags = cc_flags, shared_init = shared_init
    )
end

"""
    build_executable(
        julia_program, output_name = nothing, c_program = nothing;
        snoopfile = nothing, builddir = nothing, verbose = false, quiet = false,
        copy_julialibs = true, copy_files = nothing, release = false, Release = false,
        sysimage = nothing, precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing,
        cc = nothing, cc_flags = nothing
    )
    `julia_program` needs to be a Julia script containing a `julia_main` function, e.g. like `examples/hello.jl`
    `snoopfile` is optional and can be a Julia script which calls functions that you want to make sure to have precompiled
    `builddir` is where the compiled artifacts will end up
"""
function build_executable(
        julia_program, output_name = nothing, c_program = nothing;
        snoopfile = nothing, builddir = nothing, verbose = false, quiet = false,
        copy_julialibs = true, copy_files = nothing, release = false, Release = false,
        sysimage = nothing, precompiled = nothing, compilecache = nothing,
        home = nothing, startup_file = nothing, handle_signals = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing, depwarn = nothing,
        cc = nothing, cc_flags = nothing
    )
    static_julia(
        julia_program, cprog = c_program, verbose = verbose, quiet = quiet,
        builddir = builddir, outname = output_name, snoopfile = snoopfile, autodeps = true, executable = true,
        copy_julialibs = copy_julialibs, copy_files = copy_files, release = release, Release = release,
        sysimage = sysimage, precompiled = precompiled, compilecache = compilecache,
        home = home, startup_file = startup_file, handle_signals = handle_signals,
        compile = compile, cpu_target = cpu_target, optimize = optimize, debug = debug,
        inline = inline, check_bounds = check_bounds, math_mode = math_mode, depwarn = depwarn,
        cc = cc, cc_flags = cc_flags
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
