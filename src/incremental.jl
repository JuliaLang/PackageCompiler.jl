
"""
Init basic C libraries
"""
function InitC()
  """
  Base.reinit_stdio()
  """
end

"""
Init the package manager load paths etc
"""
function InitPkg()
  """
  Base.init_load_path()
  Base.init_depot_path()
  using Pkg, PackageCompiler
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
  @eval(M, using PackageCompiler)
  @eval(M, (Base.include(\$M, $(repr(path)))))
  """
end


"""
Fix for https://github.com/JuliaLang/julia/issues/30479
"""
function Fix30479()
    """
    _bindir = ccall(:jl_get_julia_bindir, Any, ())::String
    @eval(Sys, BINDIR = $(_bindir))
    @eval(Sys, STDLIB = joinpath($_bindir, "..", "share", "julia", "stdlib", string('v', (VERSION.major), '.', VERSION.minor)))
    """
end

"""
The command to pass to julia --output-o, that runs the julia code in `path` during compilation.
"""
function PrecompileCommand(path)
  InitC() * Fix30479() * InitPkg() * InitREPL() * Include(path)
end


function compile_incremental(package, snoopfile; reuse = false, verbose = true, optimize = nothing, debug = false, cc_flags = nothing, cc = nothing)
    sys_so = joinpath(default_sysimg_path(false), "sys.so")
    path = sysimg_folder("incremental_precompile.jl")
    reuse || snoop(package, snoopfile, path)
    command = PrecompileCommand(path)
    systemp = joinpath(sysimg_folder(), "sys.a")
    sysout = joinpath(sysimg_folder(), "sys.so")
    run(`julia -C native --output-o $systemp -J $sys_so -O3 -g1 -e "$command"`)
    build_shared(sysout, systemp, false, sysimg_folder(), verbose, "3", debug, system_compiler, cc_flags)
    return sysout
end
