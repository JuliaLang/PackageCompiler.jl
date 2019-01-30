# This code is derived from `julia-config.jl` (part of Julia) and should be kept aligned with it.

threadingOn() = ccall(:jl_threading_enabled, Cint, ()) != 0

function shell_escape(str)
    str = replace(str, "'" => "'\''")
    return "'$str'"
end

function libDir()
    return if ccall(:jl_is_debugbuild, Cint, ()) != 0
        dirname(abspath(Libdl.dlpath("libjulia-debug")))
    else
        dirname(abspath(Libdl.dlpath("libjulia")))
    end
end

private_libDir() = abspath(Sys.BINDIR, Base.PRIVATE_LIBDIR)

function includeDir()
    return abspath(Sys.BINDIR, Base.INCLUDEDIR, "julia")
end

function ldflags()
    fl = "-L$(shell_escape(libDir()))"
    if Sys.iswindows()
        fl = fl * " -Wl,--stack,8388608"
    elseif Sys.islinux()
        fl = fl * " -Wl,--export-dynamic"
    end
    return fl
end

function ldlibs()
    libname = if ccall(:jl_is_debugbuild, Cint, ()) != 0
        "julia-debug"
    else
        "julia"
    end
    if Sys.isunix()
        return "-Wl,-rpath,$(shell_escape(libDir())) -Wl,-rpath,$(shell_escape(private_libDir())) -l$libname"
    else
        return "-l$libname -lopenlibm"
    end
end

function cflags()
    flags = IOBuffer()
    print(flags, "-std=gnu99")
    include = shell_escape(includeDir())
    print(flags, " -I", include)
    if threadingOn()
        print(flags, " -DJULIA_ENABLE_THREADING=1")
    end
    if Sys.isunix()
        print(flags, " -fPIC")
    end
    return String(take!(flags))
end

function allflags()
    return "$(cflags()) $(ldflags()) $(ldlibs())"
end




const short_flag_to_jloptions = Dict(
    "C" => :cpu_target,
    "J" => :image_file,
    "O" => :opt_level,
    "g" => :debug_level
)

const flag_to_jloptions = Dict(
    "check-bounds" => :check_bounds,
    "code-coverage" => :code_coverage,
    "compile" => :compile_enabled,
    "compiled-modules" => :use_compiled_modules,
    "cpu-target" => :cpu_target,
    "depwarn" => :depwarn,
    "handle-signals" => :handle_signals,
    "history-file" => :historyfile,
    "machine-file" => :machine_file,
    "math-mode" => :fast_math,
    "optimize" => :opt_level,
    "output-bc" => :outputbc,
    "output-ji" => :outputji,
    "output-jitbc" => :outputjitbc,
    "output-o" => :outputo,
    "output-unoptbc" => :outputunoptbc,
    "project" => :project,
    "startup-file" => :startupfile,
    "sysimage" => :image_file,
    "sysimage-native-code" => :use_sysimage_native_code,
    "trace-compile" => :trace_compile,
    "track-allocation" => :malloc_log,
    "warn-overwrite" => :warn_overwrite,
    "inline" => :can_inline
)

const jl_options_to_flag = Dict(
    :can_inline => "inline",
    :handle_signals => "handle-signals",
    :opt_level => "optimize",
    :depwarn => "depwarn",
    :malloc_log => "track-allocation",
    :outputo => "output-o",
    :startupfile => "startup-file",
    :compile_enabled => "compile",
    :trace_compile => "trace-compile",
    :check_bounds => "check-bounds",
    :outputji => "output-ji",
    :use_sysimage_native_code => "sysimage-native-code",
    :outputunoptbc => "output-unoptbc",
    :historyfile => "history-file",
    :outputbc => "output-bc",
    :warn_overwrite => "warn-overwrite",
    :machine_file => "machine-file",
    :code_coverage => "code-coverage",
    :image_file => "sysimage",
    :cpu_target => "cpu-target",
    :outputjitbc => "output-jitbc",
    :project => "project",
    :fast_math => "math-mode",
    :use_compiled_modules => "compiled-modules",
    :debug_level => "g"
)

const flags_with_cmdval = Set([
    :handle_signals,
    :use_sysimage_native_code,
    :depwarn,
    :can_inline,
    :historyfile,
    :startupfile,
    :use_compiled_modules,
    :warn_overwrite,
    :check_bounds,
    :fast_math,
    :compile_enabled,
    :malloc_log,
    :code_coverage
])

function to_cmd_val(key::Symbol, val)
    # undocumented auto!? well we can only skip it I guess
    if key in (:depwarn, :warn_overwrite)
        val == 0  && return "no"
        val == 1 && return "yes"
        val == 2 && return "error"
    end
    if key in (:code_coverage, :malloc_log)
        val == 0 && return "none"
        val == 1 && return "user"
        val == 2 && return "all"
    end
    if key == :compile_enabled
        val == 0 && return "no"
        val == 1 && return "yes"
        val == 2 && return "all"
    end
    if key == :fast_math
        val == 0 && return "ieee"
        val == 1 && return "fast"
    end
    val in (0, -1) && return ""
    val == 1 && return "yes"
    val == 2 && return "no"
end


function jl_option_value(opts, key)
    value = getfield(opts, key)
    if value isa Ptr{UInt8}
        return value == C_NULL ? "" : unsafe_string(value)
    end
    if key in flags_with_cmdval
        return to_cmd_val(key, value)
    end
    return value
end

is_short_flag(flag) = haskey(short_flag_to_jloptions, flag)

function jl_option_key(flag::Symbol)
    # if symbol is used, we can also check the fields directly.
    # TODO should we also do this for strings?
    flag in fieldnames(Base.JLOptions) && return flag
    jl_option_key(string(flag))
end

function jl_option_key(flag::String)
    haskey(short_flag_to_jloptions, flag) && return short_flag_to_jloptions[flag]
    haskey(flag_to_jloptions, flag) && return flag_to_jloptions[flag]
    m_flag = replace(flag, "_" => "-")
    haskey(flag_to_jloptions, m_flag) && return flag_to_jloptions[m_flag]
    flags = replace.([keys(flag_to_jloptions)..., keys(short_flag_to_jloptions)...], ("-" => "_",))
    error("Flag $flag not a valid Julia Options. Valid flags are:\n$(join(flags, " "))")
end

"""
    extract_flag(flag, jl_cmd = Base.julia_cmd())

Extracts the value for `flag` from `jl_cmd`.
"""
function jl_flag_value(flag, jl_options = Base.JLOptions())
    jl_option_value(jl_options, jl_option_key(flag))
end

current_systemimage() = jl_flag_value("J")

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

function jl_command(flag, value)
    (value === nothing || isempty(value)) && return ""
    if is_short_flag(flag)
        string("-", flag, value)
    else
        string("--", flag, "=", value)
    end
end


function push_command!(cmd, flag, value)
    command = jl_command(flag, value)
    isempty(command) || push!(cmd.exec, command)
end

function julia_code_cmd(
        code::String, jl_options = Base.JLOptions();
        kw...
    )
    jl_cmd = Base.julia_cmd()
    cmd = `$(jl_cmd.exec[1])` # extract julia exe
    # Add the commands from the keyword arguments
    for (k, v) in kw
        jl_key = jl_option_key(k)
        flag = jl_options_to_flag[jl_key]
        push_command!(cmd, flag, v)
    end
    # add remaining commands from JLOptions
    for key in setdiff(keys(jl_options_to_flag), keys(kw))
        flag = jl_options_to_flag[key]
        push_command!(cmd, flag, jl_option_value(jl_options, key))
    end
    # for better debug, let's not make a tmp file which would get lost!
    file = sysimg_folder("run_julia_code.jl")
    open(io-> println(io, code), file, "w")
    push!(cmd.exec, file)
    cmd
end
