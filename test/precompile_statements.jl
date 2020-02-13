precompile(Tuple{typeof(Base.peek), Base.IOStream})

# https://github.com/JuliaLang/julia/issues/31156
# https://github.com/JuliaLang/PackageCompiler.jl/issues/295
precompile(Tuple{typeof(Base.permutedims), Array{Bool, 2}, Array{Int64, 1}})
precompile(Tuple{typeof(Base.permutedims), Array{Bool, 3}, Array{Int64, 1}})
precompile(Tuple{typeof(Base.permutedims), Array{UInt8, 3}, Array{Int64, 1}})
