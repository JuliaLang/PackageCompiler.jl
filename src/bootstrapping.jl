
bootstrap_fid = nothing
"""
    log_bootstrap(discard_last_session = false)

starts logging every function that is being compiled, to be later bootstrapped on top
of the existing sysimg `bootstrap(;force = true)`


`log_bootstrap(true)` erases previously logged function list

"""
function log_bootstrap(discard_last_session = false)
    stop_log_bootstrap()
    mod = discard_last_session ? "w" : "a+"
    global bootstrap_fid = open(sysimg_folder("bootstrap.csv"),mod)
    ccall(:jl_dump_compiles, Void, (Ptr{Void},), bootstrap_fid.handle)
end

"""
    stop_log_bootstrap()

stops logging

"""
function stop_log_bootstrap()
    global bootstrap_fid
    (bootstrap_fid != nothing) && close(bootstrap_fid)
    bootstrap_fid = nothing
end

"""
    bootstrap(;vanilla = false, force = false)

bootstraps a precompilation file for all methods logged using `log_bootstrap()`.
if your code is in a module that is discoverable without any modification to
`LOAD_PATH` then it should be blacklisted `blacklist(modname)` along with
any discoverable module that imports it. bootstrapping clears the logged file,
bootstrapping can be repeated and it is cumulative

"""
function bootstrap(;vanilla = false, force = false)
    generate_bootstrap_jl()
    if length(intersect(blacklist(),bootstrapped_modules())) > 0
        warn("Blacklisted modules found in previous bootstrap, reverting to
                vanilla sysimg ( clean base )")
        vanilla = true
    end
    bootstrap(sysimg_folder("bootstrap.jl"); vanilla = vanilla, force = force)
end

"""
    bootstrap(bootstrap_jl::String;vanilla = false, force = false)

bootstraps `bootstrap_jl` to the sysimg, so that at startup `julia` is in the
state as if `include(bootstrap_jl)` has already been executed.


set `force=true`
to copy over the new sysimg, or follow the instruction at the end to do it manually.
set `vanilla = true` to bootstrap over a clean sysimg in case the current sysimg is
already a bootstraped one , and you wish to start from start

"""
function bootstrap(bootstrap_jl::String;vanilla = false, force = false)
    start_path = pwd()
    image_path = sysimg_folder()
    if vanilla
        build_sysimg(image_path, bootstrap_jl)
    else
        build_sysimg(image_path, bootstrap_jl;sysimg = nothing)
    end

    sys_o = "sys.$(Libdl.dlext)"
    source = sysimg_folder(sys_o)
    dest = joinpath(default_sysimg_path(),sys_o)
    try
        !force && throw(ErrorException("force flag set to false"))
        cp(source,dest;remove_destination=true)
        info("Succesfuly bootsrapped and replaced $dest")
    catch err
        warn(err)
        info("try manually copying using\n cp $source $dest")
        info("or manually start julia with the new sysimg using\n julia -J$source")
    end
    cd(start_path) #return to the path where we entered the function
    log_bootstrap(true) #clear the log file
end

parseable(ln) = try parse(ln);true;catch false; end
function generate_bootstrap_jl()
    stop_log_bootstrap()
    blacklisted = append!(["PackageCompiler","Main"],blacklist())

    pc = SnoopCompile.read(sysimg_folder("bootstrap.csv"))[2]
    pc =  SnoopCompile.parcel(pc;blacklist = blacklisted)

    push!(blacklisted,"unknown")

    open(sysimg_folder("bootstrap.jl"), "w") do io
        println(io,"try JULIA_HOME;catch Sys.__init__();Base.early_init();end")

        for (k,v) in pc
            string(k) in blacklisted && continue
            println(io,"println(\"Precompiling $k\")")
            println(io,"try\n   import $k")
            foreach(unique(v)) do ln
                parseable(ln) && println(io,try_catch_string_tabbed(ln;tabs=1))
            end
            println(io,"catch err\n   warn(err)\nend")
            println(io,"println(\"$k DONE!\")")
        end

        v_unknown = get!(pc,:unknown,String[])
        foreach(unique(v_unknown)) do ln
            parseable(ln) && println(io,try_catch_string_tabbed(ln))
        end

        println(io,"""println("Done Precompiling!!")""")

    end
end

try_catch_string_tabbed(ln::String;tabs = 0) = begin
    ts = "   "^tabs
    string(ts*"try\n   ",
                ts*ln,"\n",
            ts*"catch err\n   ",
                ts*"println(STDERR,\"\"\"Failed: [$(ln)\"\"\")\n",
            ts*"end")
end

sys_size_MB() = stat(joinpath(default_sysimg_path(),"sys.$(Libdl.dlext)")).size/(1024*1024)

bootstrapped_modules() = begin
    julia = Base.julia_cmd().exec[1]
    mods = readlines(`$julia --startup-file=no -e "foreach(println,names(Main))"`)
    filter!(x->x ∉ ["Base","Main"],mods)
    mods
end

write_blacklist(modules) = begin
    open(sysimg_folder("blacklist.txt"),"w") do io
        foreach(modules) do s
            println(io,s)
        end
    end
end
"""
    blacklist(modules...)

blacklists zero or more modules from being precompiled when bootstrapping
using `bootstrap(;force = true)`.  if a module is imported in
some other module then that module should be blacklisted too.The blacklist
is persistant.


returns: a list of all blacklisted modules
"""
blacklist(modules...) = begin
    blkl = open(x->x |> seekstart |> readlines,sysimg_folder("blacklist.txt"),"a+")
    length(modules) == 0 && return blkl
    bmods = bootstrapped_modules()
    foreach(modules) do s
        (s in bmods) && warn("Symbol $s is blacklisted but it is already bootstrapped,\nupdates to $s will not be visible! run `bootstrap(;force = true)` again")
    end
    blkl = unique(append!(blkl,modules))
    write_blacklist(blkl)
    blkl
end
export blacklist

"""
    whitelist(modules...)

remove one or more modules from the persistant blacklist
"""
whitelist(modules...) = begin
    blkl = blacklist()
    filter!(s -> s ∉ modules,blkl)
    write_blacklist(blkl)
    blkl
end
export whitelist
