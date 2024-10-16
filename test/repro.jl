import PackageCompiler

# ENV["JULIA_DEBUG"] = "PackageCompiler"

# Make a new depot
const new_depot = mktempdir()
mkpath(joinpath(new_depot, "registries"))
ENV["JULIA_DEPOT_PATH"] = new_depot
Base.init_depot_path()

tmp = mktempdir()

app_source_dir = joinpath(dirname(dirname(pathof(PackageCompiler))), "examples/MyApp/")
app_compiled_dir = joinpath(tmp, "MyAppCompiled")

tmp_app_source_dir = joinpath(tmp, "MyApp")
cp(app_source_dir, tmp_app_source_dir)

PackageCompiler.create_app(
    tmp_app_source_dir,
    app_compiled_dir;
    incremental=false,
    force=true,
    filter_stdlibs=true,
    include_lazy_artifacts=true,
    precompile_execution_file=joinpath(app_source_dir, "precompile_app.jl"),
    executables=[
        "MyApp" => "julia_main",
        "SecondApp" => "second_main",
        "ReturnType" => "wrong_return_type",
        "Error" => "erroring",
        "Undefined" => "undefined",
    ]
)

# +++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

import PackageCompiler

# ENV["JULIA_DEBUG"] = "PackageCompiler"

# Make a new depot
const new_depot = mktempdir()
mkpath(joinpath(new_depot, "registries"))
ENV["JULIA_DEPOT_PATH"] = new_depot
Base.init_depot_path()

# tmp = mktempdir()

sysimage_stdlibs = ["Pkg"]

base_sysimage = PackageCompiler.create_fresh_base_sysimage(
    sysimage_stdlibs;
    cpu_target = PackageCompiler.default_app_cpu_target(),
    sysimage_build_args = ``,
)
