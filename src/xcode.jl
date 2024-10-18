# Get the compiler command from `get_compiler_cmd()`, and run `cc --version`, and parse the
# output to determine whether or not the compiler is an Xcode Clang.
#
# The return value is a NamedTuple of the form (; b, ver)
# b = a Bool that is true iff the compiler is an Xcode Clang.
# ver = the version number of the Xcode Clang. If it's not Xcode Clang, ver is nothing.
function _is_xcode_clt()
    cmd = `$(get_compiler_cmd()) --version`
    @debug "_active_compiler_is_xcode_clt(): Attempting to run command" cmd
    # The `ignorestatus` allows us to proceed if the command does not run successfully.
    output = "\n" * strip(read(ignorestatus(cmd), String)) * "\n"

    # If this is an Xcode Clang compiler, example output would be:
    # > Apple clang version 16.0.0 (clang-1600.0.26.3)
    # > Target: arm64-apple-darwin23.6.0
    # > Thread model: posix
    # > InstalledDir: /Library/Developer/CommandLineTools/usr/bin

    installed_dir_m = match(r"\nInstalledDir: ([\w\/]*?)\n", output)
    if isnothing(installed_dir_m)
        return (; b=false, ver=nothing)
    end
    installed_dir_str = strip(installed_dir_m[1])
    is_xcode_app = startswith(installed_dir_str, "/Applications/Xcode.app")
    is_xcode_clt = startswith(installed_dir_str, "/Library/Developer/CommandLineTools")
    if is_xcode_app || is_xcode_clt
        m = match(r"\nApple clang version ([0-9\.]*?) ", output)
        if isnothing(m)
            @warn "Could not determine the version of the Xcode Command Line Tools"
            (; b=false, ver=nothing)
        end
        ver_str = strip(m[1])
        ver = tryparse(VersionNumber, ver_str)
        if isnothing(ver)
            @warn "Could not determine the version of the Xcode Command Line Tools" ver_str
            (; b=false, ver=nothing)
        end
        b = true
    else
        b = false
        ver = nothing
    end
    return (; b, ver)
end

# Return true iff the compiler is Xcode Clang AND the Xcode CLT version is >= 15.
#
# If the user sets the JULIA_PACKAGECOMPILER_XCODE_CLT_MAJOR_VERSION environment variable,
# we skip our attempt at auto-detection, and instead use whatever value the user gave us.
function _is_xcode_clt_and_is_gte_xcode_15()
    str = strip(get(ENV, "JULIA_PACKAGECOMPILER_XCODE_CLT_MAJOR_VERSION", ""))
    ver_int = tryparse(Int, str)
    (ver_int isa Int) && return (ver_int >= 15)

    result = _is_xcode_clt()
    if result.b
        return result.ver >= v"15"
    else
        return false
    end
end
