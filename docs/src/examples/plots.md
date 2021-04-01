# [Creating a sysimage for fast plotting with Plots.jl](@id examples-plots)

A common complaint about Julia is that the "time to first plot" is a bit
longer than desired. In this example, we will create a sysimage that is made
to specifically improve this.

To get a reference, we measure the time it takes to create the first plot with
the default sysimage:

```julia-repl
julia> @time using Plots
  5.284989 seconds (5.22 M allocations: 308.954 MiB, 1.41% gc time)

julia> @time (p = plot(rand(5), rand(5)); display(p))
 13.769197 seconds (18.42 M allocations: 909.963 MiB, 1.75% gc time)
```

This is approximately 19 seconds from start of Julia to the first plot.

We now create a precompilation file with exactly this workload in a file called `precompile_plots.jl` in the current directory:


```julia
using Plots
p = plot(rand(5), rand(5))
display(p)
```

The custom sysimage is then created as:

```julia
using PackageCompiler
create_sysimage(:Plots, sysimage_path="sys_plots.so", precompile_execution_file="precompile_plots.jl")
```

If we now start Julia with the flag `--sysimage sys_plots.so` and re-time our previous commands:

```julia-repl
julia> @time using Plots
  0.000826 seconds (852 allocations: 42.125 KiB)

julia> @time (p = plot(rand(5), rand(5)); display(p))
  0.139642 seconds (468.42 k allocations: 12.176 MiB)
```

which is a sizeable speedup.

Note that since we have more stuff in our sysimage, Julia is slightly slower to
start (0.04 seconds on this machine):

```
# Default sysimage
➜ time julia  -e ''
    0.13s user 0.08s system 88% cpu 0.232 total

# Custom sysimage
➜ time julia --sysimage sys_plots.so -e ''
    0.17s user 0.10s system 94% cpu 0.284 total
```
