import PackageCompiler

sysimage_stdlibs = ["Pkg"]

base_sysimage = PackageCompiler.create_fresh_base_sysimage(
    sysimage_stdlibs;
    cpu_target = PackageCompiler.default_app_cpu_target(),
    sysimage_build_args = ``,
)
