# Get the compiler command from `get_compiler_cmd()`, and run `cc --version`, and parse the
# output to determine whether or not the compiler is an Xcode Clang.
function _is_xcode_clt()
    cmd = `$(get_compiler_cmd()) --version`
    @debug "_active_compiler_is_xcode_clt(): Attempting to run command" cmd
    output = "\n" * strip(read(ignorestatus(cmd), String)) * "\n"
    is_apple_clang = occursin(r"Apple clang version", output)
    installed_dir_m = match(r"\nInstalledDir: ([\w\/]*?)\n", output)
    if isnothing(installed_dir_m)
        return false
    end
    installed_dir_str = strip(installed_dir[1])
    is_xcode_app = startswith(installed_dir_str, "/Applications/Xcode.app/")
    is_xcode_clt = startswith(installed_dir_str, "/Library/Developer/CommandLineTools/")
    res = is_apple_clang && (is_xcode_app || is_xcode_clt)
end

# Run `pkgutil` to get the version number of the Xcode CLT (Command Line Tools), and return
# the major version number as an integer.
function _xcode_clt_major_version()
    cmd = `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables`
    @debug "_xcode_clt_major_version(): Attempting to run command" cmd
    # The `ignorestatus` allows us to proceed if the command does
    # not run successfully.
    output = "\n" * strip(read(ignorestatus(cmd), String)) * "\n"
    r = r"version: (.*)\n"
    m = match(r, output)
    if isnothing(m)
        major_version_str = nothing
    else
        major_version_str = split(m[1], '.')[1]
    end
    major_version_int = parse(Int, major_version_str)
    return major_version_int
end

# Return true iff the Xcode CLT version is >= 15.
# "gte" = greater than or equal to.
function _is_gte_xcode_15()
    major_version_int = _xcode_clt_major_version()
    isnothing(major_version_int) && return nothing
    return major_version_int >= 15
end

# Return true iff the compiler is Xcode Clang AND the Xcode CLT version is >= 15.
#
# If the user sets the JULIA_PACKAGECOMPILER_XCODE_CLT_MAJOR_VERSION environment variable,
# we skip our attempt at auto-detection, and instead use whatever value the user gave us.
function _is_xcode_clt_and_is_gte_xcode_15()
    str = strip(get(ENV, "JULIA_PACKAGECOMPILER_XCODE_CLT_MAJOR_VERSION", ""))
    ver_int = tryparse(Int, str)
    (ver_int isa Int) && return ver_int
    if _is_xcode_clt()
        b = _is_gte_xcode_15()
        if isnothing(b)
            @warn "Could not determine the version of the Command Line Tools, assuming less than or equal to 14"
        end
        return b
    else
        false
    end
end