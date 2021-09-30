# [Creating a sysimage for fast plotting with Plots.jl](@id examples-plots)

A common complaint about Julia is that the "time to first plot" is a bit
longer than desired. In this example, we will create a sysimage that is made
to improve this.

To get a reference, we measure the time it takes to create the first plot with
the default sysimage:

```julia-repl
julia> @time using Plots
  2.943946 seconds (8.11 M allocations: 567.656 MiB, 6.47% gc time)

julia> @time p = plot(rand(2,2));
  1.940742 seconds (3.29 M allocations: 197.525 MiB, 4.65% gc time)

julia> @time display(p);
  5.132217 seconds (15.00 M allocations: 847.491 MiB, 2.57% gc time, 45.95%)
```

This is approximately 19 seconds from the start of Julia to the first plot.

We now create a precompilation file with exactly this workload in a file called `precompile_plots.jl` in the current directory:


```julia
using Plots
p = plot(rand(2,2))
display(p)
```

The custom sysimage is then created as:

```julia
using PackageCompiler
create_sysimage(["Plots"], sysimage_path="sys_plots.so", precompile_execution_file="precompile_plots.jl")
```

If we now start Julia with the flag `--sysimage sys_plots.so` and re-time our previous commands:

```julia-repl
julia> @time using Plots
  0.000159 seconds (1.07 k allocations: 79.797 KiB)

julia> @time p = plot(rand(2,2));
  0.037670 seconds (74.09 k allocations: 4.703 MiB)

julia> @time display(p);
  0.331869 seconds (278.38 k allocations: 7.900 MiB)
```

which is a sizeable speedup.

Note that since we have more stuff in our sysimage, Julia is slightly slower to
start (0.35 seconds on this machine):

```
# Default sysimage
➜ time julia -e ''                        
julia -e ''  0.06s user 0.06s system 130% cpu 0.088 total

# Custom sysimage
➜ time julia --sysimage sys_plots.so -e ''
julia --sysimage sys_plots.so -e ''  0.43s user 0.30s system 347% cpu 0.211 total
```
