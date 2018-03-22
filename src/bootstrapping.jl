
bootstrap_fid = nothing
function log_bootstrap(discard_last_session = false)
    stop_log_bootstrap()
    mod = discard_last_session ? "w" : "a+"
    global bootstrap_fid = open(sysimg_folder("bootstrap.csv"),mod)
    ccall(:jl_dump_compiles, Void, (Ptr{Void},), bootstrap_fid.handle)
end

function stop_log_bootstrap()
    global bootstrap_fid
    (bootstrap_fid != nothing) && close(bootstrap_fid)
    bootstrap_fid = nothing
end

function bootstrap(;vanilla = false, force = false)
    generate_bootstrap_jl()
    bootstrap(sysimg_folder("bootstrap.jl"); vanilla = vanilla, force = force)
end

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
    end
    cd(start_path)
    log_bootstrap(true)
end

parseable(ln) = try parse(ln);true;catch false; end
function generate_bootstrap_jl()
    stop_log_bootstrap()
    pc = SnoopCompile.read(sysimg_folder("bootstrap.csv"))[2]
    pc =  SnoopCompile.parcel(pc;blacklist = ["Main"])
    blacklist = [:PackageCompiler,:unknown,:Main]
    open(sysimg_folder("bootstrap.jl"), "w") do io
        println(io,"try JULIA_HOME;catch Sys.__init__();Base.early_init();end")

        for (k,v) in pc
            k in blacklist && continue
            println(io,"println(\"precompiling $k\")")
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
