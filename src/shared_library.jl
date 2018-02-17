
function extract_func(expr::Expr)
    signature = expr.args[2]
    functype = signature.args[2]
    if functype.head == :call && functype.args[1] == :typeof
        return functype.args[2].args[2].value, signature.args[3:end] # typeof(Module.$(QuoteNode(func)))
    else # only real functions, no getfield functions will be exported
        Symbol(""), signature.args[3:end]
    end
end

function to_ctype(T)
    T == UInt8 && return "unsigned char"
    T == Bool && return "bool"
    T == Int16 && return "short"
    T == UInt16 && return "unsigned short"
    T == Int32 && return "int"
    T == UInt32 && return "unsigned int"
    T == Int64 && return "long long"
    T == UInt64 && return "unsigned long long"
    T == Int64 && return "intmax_t"
    T == UInt64 && return "uintmax_t"
    T == Float32 && return "float"
    T == Float64 && return "double"
    T == Complex{Float32} && return "complex float"
    T == Complex{Float64} && return "complex double"
    T == Int && return "ptrdiff_t"
    T == Int && return "ssize_t"
    T == UInt && return "size_t"
    T == Char && return "int"
    T == Void && return "void"
    T == Union{} && return "void "
    T == Ptr{Void} && return "void*"
    (T <: Ptr{T} where T) && return string(to_ctype(eltype(T)), "*")
    T == Ptr{Ptr{UInt8}} && return "char** "
    T == Ref{Any} && return "jl_value_t** "
    return "jl_value_t* /*$T*/ "
end


exports_function(mod, name) = name in names(mod) #

function unique_method_name(fname, used = Dict{Symbol, Int}())
    i = get!(used, fname, 0)
    used[fname] += 1
    Symbol(string(fname, i == 0 ? "" : i)) # only append number if i != 0
end


function write_ccallable(jl_io, c_io, mod, func, argtypes, used)
    argnames = map(x-> Symbol("arg_$(x)"), 1:length(argtypes))
    args = map(n_t-> Expr(:(::), n_t...), zip(argnames, argtypes))
    realfunc = getfield(mod, func)
    types = eval.(argtypes)
    returntype = Core.Inference.return_type(realfunc, types)
    method = unique_method_name(func, used)
    expr = """
    Base.@ccallable function $(method)($(join(args, ", ")))::$(returntype)
        $(mod).$(func)($(join(argnames, ", ")))
    end
    """
    println(jl_io, expr)
    ctypes = to_ctype.(types)
    # cargs = map(t_n-> join(n_t, " "), zip(argtypes, argnames))
    expr = """
    extern $(to_ctype(returntype)) $(method)($(join(ctypes, ", ")));
    """
    println(c_io, expr)
end

function emit_shared_julia(folder, mod, snoopfile, name = lowercase(string(mod)))
    open(joinpath(folder, "snoopy.jl"), "w") do io
        println(io, "include(\"$(escape_string(snoopfile))\")")
    end
    csv = joinpath(folder, "snooped.csv")
    cd(folder) do
        SnoopCompile.@snoop csv begin
            include("snoopy.jl")
        end
    end
    data = SnoopCompile.read(csv)
    pc = SnoopCompile.parcel(reverse!(data[2]))
    fname = joinpath(folder, name)
    open(fname * ".jl", "w") do jl_io
        println(jl_io, "module C_$(mod)")
        println(jl_io, "import $(mod)")
        open(fname * ".h", "w") do c_io
            println(c_io, """
            // Standard headers
            #include <string.h>
            #include <stdint.h>
            // Julia headers (for initialization and gc commands)
            #include "uv.h"
            #include "julia.h"
            """)
            used = Dict{Symbol, Int}()
            for (k, v) in pc
                for ln in v
                    # replace `_` for free parameters, which print out a warning otherwise
                    expr = parse(ln) # parse to make sure expression is parsing without error
                    funcsym, argtypes = extract_func(expr)
                    if exports_function(mod, funcsym)
                        write_ccallable(jl_io, c_io, mod, funcsym, argtypes, used)
                    end
                end
            end
            println(jl_io, "end")
        end
    end
    fname * ".jl", fname * ".h"
end

function get_module(mod::Symbol)
    eval(Main, :(using $mod))
    getfield(Main, mod)
end

function compile_sharedlib(
        folder, package_name::Symbol,
        snoopfile = Pkg.dir(string(package_name), "test", "runtests.jl")
    )
    mod = get_module(package_name)
    isdir(folder) || mkdir(folder)
    name = lowercase(string(package_name))
    shared_jl, shared_h = emit_shared_julia(folder, mod, snoopfile, name)
    builddir = joinpath(folder, "build")
    PackageCompiler.julia_compile(
        shared_jl;
        julia_program_basename = name,
        verbose = true, quiet = false, object = true,
        sysimage = nothing, cprog = nothing, builddir = builddir,
        cpu_target = nothing, optimize = nothing, debug = nothing,
        inline = nothing, check_bounds = nothing, math_mode = nothing,
        executable = false, shared = true, julialibs = true
    )
    joinpath(builddir, name * ".$(Libdl.dlext)"), shared_h
end
