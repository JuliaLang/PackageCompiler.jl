
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
    julia_compile(
        userimg_path, julia_program_basename = "sys",
        cprog = nothing, builddir = sysimg_path,
        verbose = false, quiet = false, clean = false, sysimage = nothing,
        compile = nothing, cpu_target = nothing, optimize = nothing,
        debug = nothing, inline = nothing, check_bounds = nothing,
        math_mode = nothing, depwarn = nothing, autodeps = false,
        object = true, shared = true, executable = false, julialibs = false,
        cc = system_compiler()
    )

end
