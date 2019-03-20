"""
Init basic C libraries
"""
function InitBase()
  """
  Base.__init__()
  Sys.__init__() #fix https://github.com/JuliaLang/julia/issues/30479
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

function Include(path)
  """
  M = Module()
  # Include into anonymous module to not polute namespace
  @eval(M, (Base.include(\$M, $(repr(path)))))
  """
end

"""
Exit hooks can get serialized and therefore end up in weird behaviour
When incrementally compiling
"""
function ExitHooksStart()
    """
    atexit_hook_copy = copy(Base.atexit_hooks) # make backup
    # clean state so that any package we use can carelessly call atexit
    empty!(Base.atexit_hooks)
    """
end

function ExitHooksEnd()
    """
    Base._atexit() # run all exit hooks we registered during precompile
    empty!(Base.atexit_hooks) # don't serialize the exit hooks we run + added
    # atexit_hook_copy should be empty, but who knows what base will do in the future
    append!(Base.atexit_hooks, atexit_hook_copy)
    """
end

"""
The command to pass to julia --output-o, that runs the julia code in `path` during compilation.
"""
function PrecompileCommand(path)
    ExitHooksStart() * InitBase() * InitREPL() * Include(path) * ExitHooksEnd()
end



"""
    compile_incremental(
        toml_path::String, snoopfile::String;
        force = false, precompile_file = nothing, verbose = true,
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
        precompiles::String;
        force = false, verbose = true,
        debug = false, cc_flags = nothing
    )
    systemp = sysimg_folder("sys.a")
    sysout = sysimg_folder("sys.$(Libdl.dlext)")
    code = PrecompileCommand(precompiles)
    run_julia(
        code, O = 3, output_o = systemp, g = 1,
        track_allocation = "none", startup_file = "no", code_coverage = "none"
    )
    build_shared(sysout, systemp, false, sysimg_folder(), verbose, "3", debug, system_compiler, cc_flags)
    curr_syso = current_systemimage()
    force && cp(sysout, curr_syso, force = true)
    return sysout, curr_syso
end


function compile_incremental(
        packages::Symbol...;
        kw_args...
    )
    file = package_folder("incremental_precompile.jl")
    # maybe I should have stayed with strings for packages - well now, I
    # don't want to change the api again
    snoop_packages(string.([packages...]), file; kw_args...)
    return compile_incremental(file)
end
