"""
    InitBase()
Init basic C libraries
"""
function InitBase()
    """
    Base.__init__()
    Sys.__init__() #fix https://github.com/JuliaLang/julia/issues/30479
    """
end

"""
    InitRepl()
Initialize REPL module for Docs
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
    # Include into anonymous module, so as not to pollute the namespace.
    Mod.include($(repr(path)))
    """
end

"""
    ExitHooksStart()
Exit hooks can get serialized, and therefore end up in weird behaviour
when incrementally compiling
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
    PrecompileCommand(path)
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
        precompiles::String;
        force = false, precompile_file = nothing, verbose = true,
        debug = false, cc_flags = nothing
    )

    Will ahead of time compile all precompile statements in `precompiles`.
    Will try to make sure, that all used modules in `precompiles` get resolved and loaded.
    Ignores unresolved modules. Turn on verbose to see what fails.
    `force = true` will replace the old system image with the new one.
    To compile packages, see the simpler version  `compile_incremental(packages::Symbol...)`:
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
        track_allocation = "none", startup_file = "no", code_coverage = "none",
        project = current_project()
    )
    build_shared(sysout, systemp, false, sysimg_folder(), verbose, "3", debug, system_compiler, cc_flags)
    curr_syso = current_systemimage()
    force && cp(sysout, curr_syso, force = true)
    return sysout, curr_syso
end


"""
    compile_incremental(packages::Symbol...; kw_args...)

Incrementally compile `packages` into the current system image.
`force = true` will replace the old system image with the new one.
This process requires a script that julia will run in order to determine
which functions to compile. A package may define a script called `snoopfile.jl`
for this purpose. If this file cannot be found the package's test script
`Package/test/runtests.jl` will be used. `compile_incremental` will search
for `snoopfile.jl` in the package's root directory and in the folders
`Package/src` and `Package/snoop`. For a more explicit version of compile_incremental,
see: `compile_incremental(toml_path::String, snoopfile::String)`

Not all packages can currently be compiled into the system image. By default,
`compile_incremental(:Package)` will also compile all of Package's dependencies.
It can still be desirable to compile packages with dependencies that cannot be
compiled. For this reason `compile_incremental` offers
the ability for the user to pass a list of blacklisted packages
that will be ignored during the compilation process. These are passed as a
vector of package names (defined as either strings or symbols) using the
    `blacklist keyword argument`
"""
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



function compile_project_incremental(
        project_dir::String; kw_args...
    )
    snoop = package_folder("project_precompile.jl")
    PackageCompiler.run_julia("""
        using Pkg
        open($(repr(snoop)), "w") do io
            project_dir = $(repr(abspath(project_dir)))
            Pkg.activate(project_dir)
            Pkg.instantiate()
            println(io, "using Pkg; Pkg.activate(\$(repr(project_dir)))")
            pkgs = keys(Pkg.installed())
            if !isempty(pkgs)
                println(io, "using " * join(pkgs, ", "))
            end
        end
    """)
    compile_incremental(snoop, kw_args...)
end
