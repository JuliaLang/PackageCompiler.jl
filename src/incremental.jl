
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
    extract_flag(flag, jl_cmd = Base.julia_cmd())

Extracts the value for `flag` from `jl_cmd`.
"""
function extract_flag(flag, jl_cmd = Base.julia_cmd())
    for elem in jl_cmd.exec
        if startswith(elem, flag)
            return elem
        end
    end
    return nothing
end

function extract_flag_value(flag, jl_cmd = Base.julia_cmd())
    val = extract_flag(flag, jl_cmd)
    replace(val, flag => "")
end
current_systemimage() = extract_flag_value("-J")

"""
    add_command!(cmd, ignore, jl_cmd, flag, value)

Add a command to `cmd` - either choosing the julia default if `value == nothing`,
or adds value!. If ignore = true, and command not in jl_cmd && value == nothing,
command gets not added.
"""
function add_command!(cmd, ignore, jl_cmd, flag, value)
    new_cmd = if value == nothing
        extract_flag(flag, jl_cmd)
    else
        short = !startswith(flag, "--")
        string(flag, short ? "" : "=", value)
    end
    if new_cmd == nothing
        ignore || @warn("Flag $flag not present in julia-cmd, but is set to nothing - can't add the flag")
    else
        push!(cmd, new_cmd)
    end
end

"""
    run_julia(
        code::String;
        g = nothing, O = nothing, output_o = nothing, J = nothing,
        startup_file = "no"
    )

Run `code` in a julia command.
You can overwrite any julia command line flag by setting it to a value.
If the flag has the value `nothing`, the value of the flag of the current julia process is used.
"""
function run_julia(code::String; kw...)
    run(julia_code_cmd(code; kw...))
end

function julia_code_cmd(
        code::String;
        g = nothing, O = nothing, output_o = nothing, J = nothing,
        startup_file = nothing, trace_compile = nothing, compile = nothing
    )

    jl_cmd = Base.julia_cmd()
    cmd = `$(jl_cmd.exec[1])` # extract julia exe

    add_command!(cmd.exec, false, jl_cmd, "-O", O)
    add_command!(cmd.exec, false, jl_cmd, "-J", J)

    add_command!(cmd.exec, true, jl_cmd, "-g", g)
    add_command!(cmd.exec, true, jl_cmd, "--output-o", output_o)
    add_command!(cmd.exec, true, jl_cmd, "--startup-file", startup_file)
    add_command!(cmd.exec, true, jl_cmd, "--compile", compile)
    add_command!(cmd.exec, true, jl_cmd, "--trace-compile", trace_compile)
    # for better debug, let's not make a tmp file and immediately delete it!
    file = sysimg_folder("run_julia_code.jl")
    open(io-> println(io, code), file, "w")
    push!(cmd.exec, file)
    cmd
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
