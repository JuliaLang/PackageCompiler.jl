using VersionsJSONUtil: download_url
using Pkg.BinaryPlatforms # yuck
using Downloads
using Libdl
using Glob

v = v"1.9.0"
v2 = VersionNumber(v.major, v.minor)

url = download_url(v, Linux(:x86_64; libc = :glibc))
path = Downloads.download(url)
extract_dir = mktempdir(cleanup=false)
run(`tar -xvf $path -C $extract_dir`)
jl_folder = only(readdir(extract_dir; join=true))

obligatory_stdlibs = ["GMP_jll", "MPFR_jll", "LLD_jll", "libLLVM_jll", "MozillaCACerts_jll", "LibUnwind_jll",
                      "LLVMLibUnwind_jll", "dSFMT_jll", "CompilerSupportLibraries_jll", "p7zip_jll", "PCRE2_jll",
                      "LibUV_jll", "OpenLibm_jll"]

jl_folder = abspath(Sys.BINDIR, "..")
libjulia_libraries = basename.(filter(isfile, readdir(joinpath(jl_folder, "lib"); join=true)))



if Sys.isunix() || Sys.isapple()
    libdir = joinpath(jl_folder, "lib", "julia")
    all_libraries = Set(readdir(libdir))
    delete!(all_libraries, "sys." * Libdl.dlext)
else
    libdir = joinpath(jl_folder, "bin")
    all_libraries = Set(readdir(libdir))
    delete!(all_libraries, "julia.exe")
    delete!(all_libraries, "sys.dll")
    # more?
end

d = Dict{String, Dict{String, Vector{String}}}()

# d["LLD_jll"] = Dict()
# d["LLVMLibUnwind_jll"] = Dict("mac" => ["libunwind.dylib"])
# d["MozillaCACerts_jll"] = Dict() # file
d["libblastrampoline_jll"] = Dict("mac" => ["libblastrampoline.5.dylib"], "windows" => ["libblastrampoline-5.dll"], "linux" => ["libblastrampoline.so.5.dylib"])
# d["p7zip_jll"] = Dict() # file
# "libgcc_s_seh-1.dll" vs "libgcc_s_sjlj-1.dll" on Win?

if Base.USE_BLAS64
    const libsuffix = "64_"
else
    const libsuffix = ""
end
d["OpenBLAS_jll"] = Dict("mac" => ["libopenblas$(libsuffix).dylib"], "windows" => ["libopenblas$(libsuffix).dll"], "linux" => ["libopenblas$(libsuffix).so"])

stdlibs_dir = joinpath(jl_folder, "share", "julia", "stdlib", "v" * string(v.major) * "." * string(v.minor))
for stdlib in readdir(stdlibs_dir)
    if stdlib in obligatory_stdlibs
        continue
    end
    stdlib_dir = joinpath(stdlibs_dir, stdlib)
    isdir(stdlib_dir) || continue
    if haskey(d, stdlib)
        @info "Skipping hardcoded $stdlib"
        continue
    end
    if endswith(stdlib_dir, "_jll")
        d_stdlib = get!(Dict{String, Vector{String}}, d, stdlib)
        jl_file = joinpath(stdlib_dir, "src", stdlib * ".jl")
        content = read(jl_file, String)
        matches = eachmatch(r"const lib(.*) = \"(.*)\"", content)
        if isempty(matches)
            error("no matches for $jl_file")
            continue
        end

        for m in matches
            name, file = m.captures
            if contains(file, ".dylib")
                m2 = match(r"@rpath/(.*)", file)
                file = m2.captures[1]
                os = "mac"
            elseif contains(file, ".so")
                os = "linux"
            elseif contains(file, ".dll")
                os = "windows"
            else
                error("unknown file type: $file for name $name in $jl_file")
                continue
            end
            v_lib = get!(Vector{String}, d_stdlib, os)
            @assert startswith(file, "lib")
            push!(v_lib, file)
        end

    end
end

function strip_prefix_suffix(lib, os)
    if os == "windows"
        re = r"(.*?)(-\d+)?\.dll"
    elseif os == "linux"
        re = r"(.*?)\.so"
    elseif os == "mac"
        re = r"(.*?)((\.\d+)+)?\.dylib"
    end
    m = match(re, lib)
    if m === nothing
        error("could not match $lib")
    end
    return m.captures[1]
end

d2 = Dict{String, Dict{String, Vector{String}}}()

for (stdlib, data) in d
    d2_stdlib = get!(Dict{String, Vector{String}}, d2, stdlib)
    for (os, libs) in data
        v2_lib = get!(Vector{String}, d2_stdlib, os)
        for lib in libs
            lib_stripped = strip_prefix_suffix(lib, os)
            push!(v2_lib, lib_stripped)
        end
    end
end

d3 = Dict{String, Dict{String, Vector{String}}}()
for (stdlib, data) in d2
    d3_stdlib = get!(Dict{String, Vector{String}}, d3, stdlib)
    if get(data, "windows", "") == get(data, "linux", "") == get(data, "mac", "") && get(data, "windows", "") != ""
        d3_stdlib["common"] = data["windows"]
    else
        for (os, libs) in data
            d3_stdlib[os] = libs
        end
    end
end

function glob_pattern_lib(lib)
    Sys.iswindows() ? lib * ".dll" :
    Sys.isapple() ? lib * "*.dylib" :
    Sys.islinux() ? lib* "*.so*" :
    error("unknown os")
end

remaining_libs = Set(strip_prefix_suffix.(copy(all_libraries), Sys.isunix() ? "linux" : Sys.isapple() ? "mac" : "windows"))
for (stdlib, data) in d3
    for (os, libs) in data
        for lib in libs
            if lib in remaining_libs
                @show lib
                delete!(remaining_libs, lib)
            end
        end
    end
end
delete!(remaining_libs, "libllvmcalltest")
delete!(remaining_libs, "libccalltest")
remaining_libs = sort!(collect(remaining_libs))

begin
    println("const jll_libs = Dict(")
end

begin
println("const jll_mapping = Dict(")
for (stdlib, os) in d3
    print("    ", repr(stdlib), " => ", "Dict(")
    for (os, libs) in os
        print(repr(os), " => ", repr(libs), ", ")
    end
    println("),")
end
println(")")
end
