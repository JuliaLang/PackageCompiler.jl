# PackageCompiler

Julia is, in general, a "just-barely-ahead-of-time" compiled language. When you call a function
for the first time, Julia compiles it for precisely the types of the arguments given. This can
take some time. All subsequent calls within that same session use this fast compiled function,
but if you restart Julia you lose all the compiled work. PackageCompiler allows you to do this
work upfront — further ahead of time — and store the results for a lower latency startup.

There are three main workflows:

1. You can save loaded packages and compiled functions into a file (called a
   [sysimage](@ref sysimages)) that you pass to `julia` upon startup. Typically the
   goal is to reduce latency on your machine; for example, you could load the packages
   and compile the functions used in [common plotting workflows](@ref examples-plots) use
   that saved image by default. In general, sysimages are not relocatable to other machines;
   they'll only work on the machine they were created on.

2. You can further compile an entire project into a [relocatable "app"](@ref apps).
   This generates a bundle of files (including the executable) that can be sent and run on
   other machines that might not even have Julia installed. Not only does this aim to do as
   much compilation up-front, but it also bundles together all dependencies (including
   potentially cross-platform binary libraries) and Julia itself with a single executable
   as its entry point.

3. Alternatively, you can create a [C library](@ref libraries). In this case, your package should
   define C-callable functions to be included in the sysimage. As with apps, generating a
   library bundles together Julia and all dependencies in a (hopefully) redistributable
   directory structure that can be moved to other machines (of the same architecture).

The most challenging part in all cases is in determining _which_ methods need to be
compiled ahead of time. For example, your project will certainly require addition between
integers (`+(::Int, ::Int)`; thankfully that's already compiled into Julia itself), but does
it require addition of dates (like `+(::Date, ::Day)` or `+(::DateTime, ::Hour)`)? What
about high-precision complex numbers (`+(::Complex{BigFloat}, ::Complex{BigFloat})`)? It's
completely intractable to compile all possible combinations, so instead PackageCompiler
relies upon ["tracing" an exemplar session](@ref tracing) and recording which methods were
used. Any methods that were missed will still be compiled as they are needed (by default).

Note that to use PackageCompiler.jl effectively some knowledge on how
packages and ["environments"](https://julialang.github.io/Pkg.jl/v1/environments/) work
is required. If you are just starting with Julia, it is unlikely that you would
want to use PackageCompiler.jl

-----

The manual contains some uses of Linux commands like `ls` (`dir` in Windows)
and `cat` but hopefully these commands are common enough that the points still
come across.

## Installation instructions

The package is installed using the standard way with the package manager:

```julia
using Pkg
Pkg.add("PackageCompiler")
```

!!! note
    It is strongly recommended to use the official binaries that are downloaded from 
    https://julialang.org/downloads/. Distribution-provided Julia installations are
    unlikely to work properly with this package.
 
To use PackageCompiler a C-compiler needs to be available:

### macOS, Linux

Having a decently modern `gcc` or `clang` available should be enough to use PackageCompiler on Linux or macOS.
For macOS, this can be the built-in Xcode command line tools or `homebrew` and for Linux, using the system package
manager to get a compiler should work fine.

### Windows

A suitable compiler will be automatically installed the first time it is needed.

## Upgrading from PackageCompiler 1.0.

PackageCompiler 2.0 comes with a few breaking changes.

- The functionality for replacing the default sysimage (`replace_default=true`) has been removed. Instead, you can e.g.
  create an alias or shortcut that starts Julia with a custom sysimage by specifying the `--sysimage=<PATH/TO/SYSIMAGE>`
  command line option.
- Lazy artifacts (those not downloaded until used) are not included in apps by default anymore. Use `include_lazy_artifacts=true` to re-enable this.
- Passing no packages to `create_sysimage` will now include all packages in the given project instead of a sysimage with no packages.
  Use `String[]` as a first argument if you want the old behavior.
- The `audit_app` function has been removed. It caught too few problems to be useful in practice.
- The keyword `app_name` in `create_app` has been removed and replaced with a more flexible version.
  If you used `app_name="Foo"`, replace it with `executables=["Foo"=>"julia_main"]`.
- The `@ccallable` in front of the entry point functions of apps should be removed. Failure to do so might lead to strange errors during creation of the app.
