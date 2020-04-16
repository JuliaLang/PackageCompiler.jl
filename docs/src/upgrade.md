# [Upgrade from pre 1.0 PackageCompiler](@id upgrade)

PackageCompiler.jl got [significantly
changed](https://github.com/JuliaLang/PackageCompiler.jl/pull/304) for the 1.0
release. This page is intended to provide some guidance in transitioning from
the previous PackageCompiler to PackageCompiler 1.0. PackageCompiler 1.0 has
quite extensive documentation which, in addition to this page, contains useful
information when upgrading.

If you want to keep using the older version of PackageCompiler you can add
an entry

```toml
[compat]
PackageCompiler = "0.6"
```

to your project file.


### General notes

- PackageCompiler.jl now requires Julia 1.3.1.
- There is no command-line interface anymore

### Sysimages

- The function to create a sysimage is now called [`create_sysimage`](@ref) instead of `compile_incremental`.
- The tests of packages are no longer automatically run to gather precompile statements. If you wish to keep using package tests you can see an example of that in the documentation for creating a sysimage.


### Executables
- The function to create an executable is now called [`create_app`](@ref) instead of `build_executable`.
- The `julia_main` function for executables should no longer take any arguments
  (just access the global `ARGS`) and no longer need to be annotated with
  `Base.@ccallable`.
- The code for an executable need to be structured as a package, that is, with a
  `Project.toml` file and a `src/Package.jl` file etc.
- See https://github.com/JuliaLang/PackageCompiler.jl/tree/master/examples/MyApp for
  an example of the source code for an executable.
