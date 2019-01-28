"""
Init basic C libraries
"""
function InitBase()
  """
  Base.__init__()
  """
end

"""
# Initialize REPL module for Docs
"""
function InitREPL()
  """
  using REPL
  Base.REPL_MODULE_REF[] = REPL
  """
end

"""
Fix for https://github.com/JuliaLang/julia/issues/30479
"""
function Fix30479()
    """
    _bindir = ccall(:jl_get_julia_bindir, Any, ())::String
    @eval(Sys, BINDIR = \$(_bindir))
    @eval(Sys, STDLIB = joinpath(\$_bindir, "..", "share", "julia", "stdlib", string('v', (VERSION.major), '.', VERSION.minor)))
    """
end

function Include(path)
  """
  M = Module()
  # Include into anonymous module to not polute namespace
  @eval(M, (Base.include(\$M, $(repr(path)))))
  """
end

"""
The command to pass to julia --output-o, that runs the julia code in `path` during compilation.
"""
function PrecompileCommand(path)
    InitBase() * Fix30479() * InitREPL() * Include(path)
end

"""
    compile_incremental(
        toml_path::String, snoopfile::String;
        force = false, reuse = false, verbose = true,
        debug = false, cc_flags = nothing
    )

    Extract all calls from `snoopfile` and ahead of time compiles them
    incrementally into the current system image.
    `force = true` will replace the old system image with the new one.
    The argument `toml_path` should contain a project file of the packages that `snoopfile` explicitly uses.
    Implicitly used packages & modules don't need to be contained!

    To compile just a single package, see the simpler version  `compile_incremental(package::Symbol)`:
"""
function compile_incremental(
        toml_path::String, snoopfile::String;
        force = false, reuse = false, verbose = true,
        debug = false, cc_flags = nothing
    )
    precompiles = package_folder("incremental_precompile.jl")
    reuse || snoop(toml_path, snoopfile, precompiles)
    systemp = joinpath(sysimg_folder(), "sys.a")
    sysout = joinpath(sysimg_folder(), "sys.$(Libdl.dlext)")
    code = PrecompileCommand(precompiles)
    run_julia(code, O = 3, output_o = systemp, g = 1)
    build_shared(sysout, systemp, false, sysimg_folder(), verbose, "3", debug, system_compiler, cc_flags)
    curr_syso = current_systemimage()
    force && cp(sysout, curr_syso, force = true)
    return sysout, curr_syso
end

"""
    compile_incremental(
        package::Symbol;
        force = false, reuse = false, verbose = true,
        debug = false, cc_flags = nothing
    )

    Incrementally compile `package` into the current system image.
    `force = true` will replace the old system image with the new one.
    `compile_incremental` will run the `Package/test/runtests.jl` file to
    and record the functions getting compiled. The coverage of the Package's tests will
    thus determine what is getting ahead of time compiled.
    For a more explicit version of compile_incremental, see:
    `compile_incremental(toml_path::String, snoopfile::String)`
"""
function compile_incremental(package::Symbol; kw...)
    toml, testfile = package_toml(package)
    compile_incremental(toml, testfile; kw...)
end
