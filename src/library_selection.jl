
# bin/refresh_library_mapping.jl
const jll_mapping = Dict(
    "libblastrampoline_jll" => ["libblastrampoline"],
    "LibCURL_jll" => ["libcurl"],
    "LibSSH2_jll" => ["libssh2"],
    "MbedTLS_jll" => ["libmbedcrypto", "libmbedtls", "libmbedx509"],
    "OpenBLAS_jll" => ["libopenblas64_", "libopenblas"],
    "nghttp2_jll" => ["libnghttp2"],
    "LibGit2_jll" => ["libgit2"],
    "SuiteSparse_jll" => ["libamd", "libbtf", "libcamd", "libccolamd", "libcholmod", "libcolamd", "libklu", "libldl", "librbio", "libspqr", "libsuitesparseconfig", "libumfpack"],
)

# Manually fixup of libLLVM
const required_libraries = Dict(
    "windows" => ["libLLVM", "libatomic", "libdSFMT", "libgcc_s_seh", "libgfortran", "libgmp", "libgmpxx", "libgomp", "libjulia-codegen", "libjulia-internal", "libmpfr", "libopenlibm", "libpcre2", "libpcre2-16", "libpcre2-32", "libpcre2-8", "libpcre2-posix", "libquadmath", "libssp", "libstdc++", "libuv", "libwinpthread", "libz"],
    "linux" =>   ["libLLVM", "libatomic", "libdSFMT", "libgcc_s",     "libgfortran", "libgmp", "libgmpxx", "libgomp", "libjulia-codegen", "libjulia-internal", "libmpfr", "libopenlibm", "libpcre2-8",                                                             "libquadmath", "libssp", "libstdc++", "libunwind", "libuv", "libz"],
    "mac" =>     ["libLLVM", "libatomic", "libdSFMT", "libgcc_s",     "libgfortran", "libgmp", "libgmpxx", "libgomp", "libjulia-codegen", "libjulia-internal", "libmpfr", "libopenlibm", "libpcre2-8",                                                             "libquadmath", "libssp", "libstdc++", "libuv", "libz"]
)
push!(required_libraries["windows"], "libgcc_s_jlj")
if Sys.VERSION < v"1.7.0"
    push!(required_libraries["mac"], "libosxunwind")
else
    push!(required_libraries["mac"], "libunwind")
end
