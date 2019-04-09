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
    Mod = @eval module \$(gensym("anon_module")) end
    # Include into anonymous module to not polute namespace
    Mod.include($(repr(path)))
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

function PackageCallbacksStart()
    """
    package_callbacks_copy = copy(Base.package_callbacks)
    empty!(Base.package_callbacks)
    """
end

function PackageCallbacksEnd()
    """
    empty!(Base.package_callbacks)
    append!(Base.package_callbacks, package_callbacks_copy)
    """
end

function REPLHooksStart()
    """
    repl_hooks_copy = copy(Base.repl_hooks)
    empty!(Base.repl_hooks)
    """
end

function REPLHooksEnd()
    """
    empty!(Base.repl_hooks)
    append!(Base.repl_hooks, repl_hooks_copy)
    """
end

function DisableLibraryThreadingHooksStart()
    """
    if isdefined(Base, :disable_library_threading_hooks)
        disable_library_threading_hooks_copy = copy(Base.disable_library_threading_hooks)
        empty!(Base.disable_library_threading_hooks)
    end
    """
end

function DisableLibraryThreadingHooksEnd()
    """
    if isdefined(Base, :disable_library_threading_hooks)
        empty!(Base.disable_library_threading_hooks)
        append!(Base.disable_library_threading_hooks, disable_library_threading_hooks_copy)
    end
    """
end

"""
The command to pass to julia --output-o, that runs the julia code in `path` during compilation.
"""
function PrecompileCommand(path)
    ExitHooksStart() *
        PackageCallbacksStart() *
        REPLHooksStart() *
        DisableLibraryThreadingHooksStart() *
        InitBase() *
        InitREPL() *
        Include(path) *
        DisableLibraryThreadingHooksEnd() *
        REPLHooksEnd() *
        PackageCallbacksEnd() *
        ExitHooksEnd()
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
        toml_path::Union{String, Nothing}, precompiles::String;
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

"""
    compile_incremental(
        packages::Symbol...;
        force = false, reuse = false, verbose = true,
        debug = false, cc_flags = nothing,
        blacklist::Vector = []
    )

    Incrementally compile `package` into the current system image.
    `force = true` will replace the old system image with the new one.
    This process requires a script that julia will run in order to determine
    which functions to compile. A package may define a script called `snoopfile.jl`
    for this purpose. If this file cannot be found the package's test script
    `Package/test/runtests.jl` will be used. `compile_incremental` will search
    for `snoopfile.jl` in the package's root directory and in the folders
    `Package/src` and `Package/snoop`. For a more explicit version of compile_incremental,
    see: `compile_incremental(toml_path::String, snoopfile::String)`

    Not all packages can currently be compiled into the system image. By default,
    `compile_incremental(:Package) will also compile all of Package's dependencies.
    It can still be desirable to compile packages with dependencies that cannot be
    compiled. For this reason `compile_incremental` offers
    the ability for the user to pass a list of blacklisted packages
    that will be ignored during the compilation process. These are passed as a
    vector of package names (defined as either strings or symbols) using the
    `blacklist keyword argument`
"""
function compile_incremental(pkg::Symbol, packages::Symbol...;
                             blacklist::Vector=[], kw...)
    toml, precompile = snoop_packages(pkg, packages...; blacklist=blacklist)
    compile_incremental(toml, precompile; kw...)
end
