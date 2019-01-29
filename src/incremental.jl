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
    ExitHooksStart() * InitBase() * Fix30479() * InitREPL() * Include(path) * ExitHooksEnd()
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
        toml_path::Union{String, Nothing}, snoopfile::Union{String, Nothing};
        force = false, precompile_file = nothing, verbose = true,
        debug = false, cc_flags = nothing
    )
    precompiles = package_folder("incremental_precompile.jl")
    if snoopfile == nothing && precompile_file != nothing
        # we directly got a precompile_file
        isfile(precompile_file) || error("Need to pass an existing file to precompile_file. Found: $(repr(precompile_file))")
        if precompile_file != precompiles
            cp(precompile_file, precompiles, force = true)
        end
    else
        snoop(toml_path, snoopfile, precompiles)
    end
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


function compile_incremental(packages::Symbol...; kw...)
    finaltoml = Dict{Any, Any}(
        "deps" => Dict(),
        "compat" => Dict(),
    )
    precompiles_all = package_folder("incremental_precompile.jl")
    for package in packages
        precompiles = package_folder(string(package), "incremental_precompile.jl")
        toml, testfile = package_toml(package)
        snoop(toml, testfile, precompiles)
        pkg_toml = TOML.parsefile(toml)
        merge!(finaltoml["deps"], get(pkg_toml, "deps", Dict()))
        merge!(finaltoml["compat"], get(pkg_toml, "compat", Dict()))
        open(precompiles_all, "a") do io
            println(io)
            write(io, read(precompiles))
        end
    end
    toml = package_folder("Project.toml")
    finaltoml["name"] = "PackagesPrecompile"
    open(toml, "w") do io
        TOML.print(
            io, finaltoml,
            sorted = true, by = key-> (Types.project_key_order(key), key)
        )
    end
    compile_incremental(toml, nothing; precompile_file = precompiles_all)
end
