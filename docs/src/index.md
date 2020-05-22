# PackageCompiler

Julia is, in general, a "just-barely-ahead-of-time" compiled language. When you call a function
for the first time, Julia compiles it for precisely the types of the arguments given. This can
take some time. All subsequent calls within that same session use this fast compiled function,
but if you restart Julia you lose all the compiled work. PackageCompiler allows you to do this
work up front — further ahead of time — and store the results for a lower latency startup.

There are two main workflows:

1. You can save loaded packages and compiled functions into a file (called a
    [sysimage](@ref sysimages)) that you pass to `julia` upon startup. Typically the
    goal is to reduce latency on your own machine; for example you could load the packages
    and compile the functions used in [common plotting workflows](@ref examples-plots) use
    that saved image by default. In general, sysimages not relocatable to other machines;
    they'll only work on the machine they were created on.

2. You can further compile an entire project into a [relocatable "app"](@ref apps).
    This generates a bundle of files (including the executable) that can be sent and run on
    other machines that might not even have Julia installed. Not only does this aim to do as
    much compilation up-front, but it also bundles together all dependencies (including
    potentially cross-platfrom binary libraries) and Julia itself with a single executable
    as its entry point.

The most challenging part in both cases is in determining _which_ methods need to be
compiled ahead of time. For example, your project will certainly require addition between
integers (`+(::Int, ::Int)`; thankfully that's already compiled into Julia itself), but does
it require addition of dates (like `+(::Date, ::Day)` or `+(::DateTime, ::Hour)`)? What
about high-precision complex numbers (`+(::Complex{BigFloat}, ::Complex{BigFloat})`)? It's
completely intractable to compile all possible combinations, so instead PackageCompiler
relies upon ["tracing" an exemplar session](@ref tracing) and recording which methods were
used. Any methods that were missed will still be compiled as they are needed (by default).

Note that to use PackageCompiler.jl effectively some knowledge on how
packages and ["environments"](https://julialang.github.io/Pkg.jl/v1/environments/) work
is required. If you are just starting out with Julia, it is unlikely that you would
want to use PackageCompiler.jl

-----

The manual contains some uses of Linux commands like `ls` (`dir` in Windows)
and `cat` but hopefully these commands are common enough that the points still
come across.

## Installation instructions

!!! note

    It is strongly recommended to use the official binaries that are downloaded from 
    https://julialang.org/downloads/. Distribution-provided Julia installations are
    unlikely to work properly with this package.
  
To use PackageCompiler a C-compiler needs to be available:

### macOS, Linux

Having a decently modern `gcc` or `clang` available should be enough to use PackageCompiler on Linux or macOS.
For macOS, this can be the builtin xcode command line tools or `homebrew` and for Linux the system package manager should work fine.

### Windows

A suitable compiler will be automatically installed the first time it is needed.

## Upgrading from pre 1.0 PackageCompiler

There are some notes to facilitate upgrading from the earlier version of
PackageCompiler [here](@ref upgrade)
