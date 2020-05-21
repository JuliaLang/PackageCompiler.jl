# [Creating a sysimage](@id man-tutorial-sysimage)

## Julia's compilation model and sysimages

Julia is a JIT-compiled language. More specifically, functions are compiled
just before getting executed. A more suitable description of the Julia
compilation model might, therefore, be Just-Ahead-of-Time (JAOT) compilation.
The term JIT is sometimes used to describe the compilation model where code is
dynamically recompiled based on runtime performance data, which Julia does not
do. At the same time, Julia comes with a lot of built-in functionality
including several standard libraries. If all this built-in functionality would
need to be parsed, type inferred and compiled every time Julia started, the
startup-time would be longer than reasonable. Therefore, Julia bundles
something called a "sysimage" which is a [shared
library](https://en.wikipedia.org/wiki/Library_(computing)#Shared_libraries)
where (roughly) the state of a running Julia session has been stored
(serialized).  When Julia starts, this sysimage gets loaded, which is a quite
quick process (50ms on the author's machine), and all the cached compiled code
can immediately be used, without requiring any compilation.

## Custom sysimages

There are cases where one wants to generate a custom sysimage for a similar
reason as to why Julia bundles one: to reduce time from Julia start until the
program is executing. The time from startup to execution is here denoted as
"latency" and we want to minimize the latency of our program.  A drawback of
putting a package inside the sysimage is that it becomes "frozen" at the
particular version it was, when it got put into the sysimage. In addition, all
the dependencies of the package put into the sysimage will be frozen in the
same manner.  In particular, it will no longer be updated like normal packages
when using the package manager. In some cases, other ways of reducing latency
might be preferable, for example, using [Revise.jl](https://github.com/timholy/Revise.jl)

## Example workload

To have something concrete to work with, let's assume we have a small script
that reads a CSV-file and computes some statistics on it.  As an example, we
will use a sample CSV file containing Florida insurance data, which can be
downloaded [from
here](http://spatialkeydocs.s3.amazonaws.com/FL_insurance_sample.csv.zip).

One way of loading this file into Julia is by using the `CSV.jl` package. We
can install `CSV.jl` using the Julia package manager `Pkg` as:

```julia-repl
julia> import Pkg; Pkg.add("CSV")
 Resolving package versions...
  Updating `~/.julia/environments/v1.3/Project.toml`
  [336ed68f] + CSV v0.5.13
  Updating `~/.julia/environments/v1.3/Manifest.toml`
 [no changes]
```

When a package is loaded for the first time it gets "precompiled":

```julia-repl
julia> @time using CSV
[ Info: Precompiling CSV [336ed68f-0bac-5ca0-87d4-7b16caf5d00b]
 13.321758 seconds (2.69 M allocations: 151.302 MiB, 0.05% gc time)
```

The term "precompiled" can be a bit misleading since there is no native
compiled code cached in the precompilation file. Julia is dynamically typed so
it is not obvious what types to compile the different methods for.

Even with `CSV` "precompiled", there is a still some loading time, but it is
significantly lower:

```julia-repl
julia> @time using CSV
  0.694224 seconds (1.90 M allocations: 114.210 MiB)
```

Let's load the sample CSV file:


```julia-repl
julia> @time CSV.read("FL_insurance_sample.csv");
9.264898 seconds (37.17 M allocations: 2.278 GiB, 3.90% gc time)1
```

That's is quite a long time to read a smallish CSV file. One way to check
the compilation overhead is by running the function again:

```julia-repl
julia> @time CSV.read("FL_insurance_sample.csv");
  0.083543 seconds (423 allocations: 34.695 KiB)
```

So clearly, the first call to the function is dominated by compilation time.
In many cases, this is not a problem in practice since often one wants to parse
multiple CSV files such that the overhead will become negligible or one keeps a
Julia session open for a longer time so that the compiled version of the
function is still in memory.

However, since the end goal of this blog series is to create an executable that
can be distributed we want to try to avoid as much runtime compilation
(latency) as possible.

## Creating a custom sysimage

If we time the loading of a standard library, it is clear that it is "cached"
somehow since the time to load it is so short:

```julia-repl
julia> @time using Dates
  0.000816 seconds (1.25 k allocations: 65.625 KiB)
```

Since `Dates` is a standard library it comes bundled in the system image.  In
fact, `Dates` is already "loaded" when starting Julia. The effect of running
`using Dates` just makes the module available in the `Main` module namespace
which is what the REPL evaluates in.

Delving into some internals, there is a dictionary in `Base` that keeps track
of all loaded modules:

```julia-repl
julia> Base.loaded_modules
Dict{Base.PkgId,Module} with 33 entries:
  SHA [ea8e919c-243c-51af-8825-aaa63cd721ce]              => SHA
  Profile [9abbd945-dff8-562f-b5e8-e1ebf5ef1b79]          => Profile
  Dates [ade2ca70-3891-5945-98fb-dc099432e06a]            => Dates
  Mmap [a63ad114-7e13-5084-954f-fe012c677804]             => Mmap
...
```

and we can here see the `Dates` module is there, even after restarting Julia.
This means that `Dates` is in the sysimage itself and does not have to be loaded
from anywhere external.

Creating and using a custom sysimage is done in three steps:

1. Start Julia with the `--output-o=sys.o custom_sysimage.jl` where
   `custom_sysimage.jl` is a file that creates the state that we want the
   sysimage to contain and `sys.o` is the resulting [object
   file](https://en.wikipedia.org/wiki/Object_file) that we will turn into a
   sysimage.
2. Create a shared library from the object file by linking it with `libjulia`.
   This is the actual sysimage.
3. Use the custom sysimage in Julia with the `-Jpath/to/sysimage` (or the
   longer, more descriptive `--sysimage`) flag.

### 1. Creating the object file

For now, the goal is to put `CSV` in the sysimage (in the same way as the
standard library `Dates` is in it). We therefore initially simply create a file
called `custom_sysimage.jl` with the content.

```julia
using CSV
```

in a `custom_sysimage.jl` file. Let's try using the flag `--output-o` (and
disabling using the startup file) and running the file:

```
julia --startup-file=no --output-o=sys.o -- custom_sysimage.jl
ERROR: could not open file boot.jl
```

That did not work well. It turns out that when using the `--output-o` option one
has to explicitly give a sysimage path ([due to this
line](https://github.com/JuliaLang/julia/blob/49fb7924498e9fe813444cc684a24002e75b2ac9/src/jloptions.c#L533)).  Since we do not have a custom sysimage yet we
just want to give the path to the default sysimage which we can get the path to
via:

```julia-repl
julia> unsafe_string(Base.JLOptions().image_file)
"/home/kc/julia/lib/julia/sys.so"
```

Let's try again, specifying the default sysimage path with the `-J` flag:

```
julia --startup-file=no --output-o sys.o -J"/home/kc/julia/lib/julia/sys.so" custom_sysimage.jl
signal (11): Segmentation fault
in expression starting at none:0
uv_write2 at /workspace/srcdir/libuv/src/unix/stream.c:1397
uv_write at /workspace/srcdir/libuv/src/unix/stream.c:1492
jl_uv_write at /buildworker/worker/package_linux64/build/src/jl_uv.c:476
uv_write_async at ./stream.jl:967
uv_write at ./stream.jl:924
```

Failure again! Another caveat when using `--output-o` is that modules
`__init__()` functions do not end up getting called, which is what normally
happens when a module is loaded. The reason for this is that often the state
that gets defined in `__init__` is not something that you want to serialize to
a file. In this particular case, some parts of the IO system have not been
initialized so Julia crashes while trying to print an error. The magic
incantation to make IO work properly is `Base.reinit_stdio()`. To figure out
the actual problem we modify the `custom_sysimage.jl` file to look like:

```julia
Base.reinit_stdio()
using CSV
```


and rerun the julia-command:

```
julia --startup-file=no --output-o sys.o -J"/home/kc/julia/lib/julia/sys.so" custom_sysimage.jl
ERROR: LoadError: ArgumentError: Package CSV not found in current path:
- Run `import Pkg; Pkg.add("CSV")` to install the CSV package.

Stacktrace:
 [1] require(::Module, ::Symbol) at ./loading.jl:887
 [2] include at ./boot.jl:328 [inlined]
 [3] include_relative(::Module, ::String) at ./loading.jl:1105
 [4] include(::Module, ::String) at ./Base.jl:31
 [5] exec_options(::Base.JLOptions) at ./client.jl:295
 [6] _start() at ./client.jl:468
in expression starting at /home/kc/custom_sysimage.jl:2
```

Okay, now we can see the error. Julia can not find the `CSV`
package.  Package-loading in Julia is based on the two arrays `LOAD_PATH` and
`DEPOT_PATH`. Adding `@show LOAD_PATH` and `@show DEPOT_PATH` to the
`custom_sysimage.jl` file and rerunning the command above prints:

```julia
LOAD_PATH = String[]
DEPOT_PATH = String[]
```

Again, we have an initialization problem. Looking at [what Julia itself does
before including the standard libraries](https://github.com/JuliaLang/julia/blob/88c34fc51d962aaef973935942b2e073e2e2f398/base/sysimg.jl#L13-L14), we can see that
the functions initializing these variables are explicitly called. Let us do the
same by updating the `custom_sysimage.jl` file to:

```julia
Base.init_depot_path()
Base.init_load_path()

using CSV

empty!(LOAD_PATH)
empty!(DEPOT_PATH)
```

and running

```
julia --startup-file=no --output-o sys.o -J"/home/kc/julia/lib/julia/sys.so" custom_sysimage.jl
```

This time, after some waiting (2 min on the authors quite beefy computer) we do
end up with a `sys.o` file.

### 2. Creating the sysimage shared library from the object file

The goal in this part is to take the object file, link it with `libjulia` to
finally produce a shared library which is our sysimage.  For this, we need to
use a C-compiler e.g. `gcc`. We need to link with `libjulia` so we need to give
the compiler the path to where the julia library resides which can be gotten
by:

```julia-repl
julia> abspath(Sys.BINDIR, Base.LIBDIR)
"/home/kc/julia/lib"
```

We tell `gcc` that we want a shared library with the `-shared` flag and to keep
all symbols into the library by passing the `--whole-archive` to the linker
(this is on Linux, see the later section for platform differences).  The final
`gcc` invocation ends up as:

```
gcc -shared -o sys.so -Wl,--whole-archive sys.o -Wl,--no-whole-archive -L"/home/kc/julia/lib" -ljulia
```

which creates the sysimage `sys.so`.

We can compare the size of the new sysimage versus the default one and see that the
new is a bit larger due to the extra packages it contains:

```julia-repl
julia> stat("sys.so").size / (1024*1024)
162.16205596923828

julia> stat(unsafe_string(Base.JLOptions().image_file)).size / (1024*1024)
147.0646743774414
```

#### Platform differences

##### macOS

On `macOS` the linker flag `-Wl,--whole-archive` is instead written as
`-Wl,-all_load` so the command would be

```
gcc -shared -o sys.dylib -Wl,-all_load sys.o -L"/home/kc/Applications/julia-1.3.0-rc4/lib" -ljulia
```

Note that the extension has been changed from `so` to `dylib` which is the
convention for shared libraries on macOS.

##### Windows

Getting a compiler toolchain on Windows that works well with Julia is a bit
trickier than on Linux or macOS.  One quite simple way is to follow the same
process as needed to compile Julia on windows as outlined
[here](https://github.com/JuliaLang/julia/blob/master/doc/build/windows.md#cygwin-to-mingw-cross-compiling) and then use the `x86_64-w64-mingw32-gcc`
compiler in Cygwin instead of `gcc`. Alternatively, a mingw compiler can be
downloaded [from
here](https://sourceforge.net/projects/mingw-w64/files/mingw-w64/) The
`libjulia` is also in a different location on Windows. Instead of the `lib`
folder it is in the `bin` folder.  Other than that, the same flags as for Linux
should work to produce the sysimage shared library.

### 3. Running Julia with the new sysimage

We start Julia with the `-Jsys.so` flag to load the new custom `sys.so` sysimage (or `sys.dylib`, `sys.dll` on macOS and Windows respecitively)
and indeed loading CSV is now very fast:

```julia-repl
julia> @time using CSV
  0.000432 seconds (665 allocations: 32.656 KiB)
```

In fact, restarting Julia and looking at `Base.loaded_modules` we can see that, just like the standard libraries, CSV and
its dependencies are already loaded when Julia is started:

```julia-repl
julia> Base.loaded_modules
Dict{Base.PkgId,Module} with 52 entries:
   Parsers [69de0a69-1ddd-5017-9359-2bf0b02dc9f0] => Parsers
...
   CSV [336ed68f-0bac-5ca0-87d4-7b16caf5d00b]     => CSV
...
```

However, remember that a large part of the latency was not loading the package
but to compile the functions used by CSV the first time. Let's try it with the
custom sysimage:


```julia-repl
julia> @time using CSV
  0.001487 seconds (711 allocations: 35.203 KiB)

julia> @time CSV.read("FL_insurance_sample.csv");
  3.609626 seconds (16.34 M allocations: 795.619 MiB, 5.88% gc time)

julia> @time CSV.read("FL_insurance_sample.csv");
  0.026917 seconds (423 allocations: 34.695 KiB)
```

Reading the CSV file is significantly faster than before but still a lot slower
than the second time.  As previously mentioned, the native code for the
functions in CSV is not compiled just by loading the package.  This means that
even though CSV is in the sysimage the functions in CSV still need to be
compiled.  The reason why the first call is faster at all is likely that
loading packages can invalidate other methods and they thus have to be
recompiled. With CSV in the sysimage, these invalidations have already been
resolved.


## Recording precompile statements

We are now at the stage where we have CSV in the sysimage, but we still suffer
some latency because of compilation.
Note that Julia is a dynamically typed language, it is therefore not known statically
what types will be used in functions. Therefore, in order to be able to compile code
one needs to know what types functions should be compiled for. One way to do this is to run
some representative workload and record what types functions end up getting called with.
This is a little bit like [Profile Guide Optimization (PGO)](https://en.wikipedia.org/wiki/Profile-guided_optimization)
while it here being something more like Profile Guided Compilation..

There is indeed a way for Julia to record what functions are getting compiled.
We can save these and then when building the sysimage tell Julia to compile and store
the native code for these functions.

We create a file called `generate_csv_precompile.jl` containing some "training
code" that we will use as a base to figure out what functions end up getting
compiled:

```julia
using CSV
CSV.read("FL_insurance_sample.csv")
```

We then make julia run this code but we add the  `--trace-compile` flag to
output "precompilation statements" to a file:

```
julia --startup-file=no --trace-compile=csv_precompile.jl generate_csv_precompile.jl
```

Looking at `csv_precompile.jl` we can see hundreds of functions that end up getting compiled.
For example, the line

```julia
precompile(Tuple{typeof(CSV.getsource), String, Bool})
```

instructs julia to compile the function `CSV.getsource` for the arguments of
type `String` and `Bool`.

Note that some of the symbols in the list of precompile statements have a bit
of a weird syntax containing `Symbol(#...)`, e.g:

```julia
precompile(Tuple{typeof(Base.map), getfield(CSV, Symbol("##4#5")), Base.SubString{String}})
```

These are symbols that were not explicitly named in the source code but that
Julia automatically gave an internal name to refer to.  These symbols are not
necessarily consistent between different Julia versions or even Julia built for
different operating systems.  It is possible to make the precompile statements
more portable by filtering out any symbols starting with `#` but that naturally
leaves some latency on the table since these now have to be compiled during runtime.

The way we make Julia cache the compilation of the functions in the list is
simply by executing the statement on each line when the sysimage is created. It
, unfortunately, isn't as simple as just adding an `include("csv_precompile")`
to our `custom_precompile.jl` file.  Firstly, all the modules used in the
precompilation statements (like `DataFrames`) are not defined in the Main
namespace. Secondly, due to [some bugs in the way Julia export precompile
statements](https://github.com/JuliaLang/julia/issues/28808) running a
precompile statement can fail.  The solution to these issues is to load all
modules in the sysimage by looping through `Base.loaded_modules` and to use a
`try-catch` for each precompile statement.  In addition, we evaluate everything
in an anonymous module to not pollute the `Main` module which a bunch of
symbols.

The end result is a `custom_sysimage.jl` file looking like:

```julia
Base.init_depot_path()
Base.init_load_path()

using CSV

@eval Module() begin
    for (pkgid, mod) in Base.loaded_modules
        if !(pkgid.name in ("Main", "Core", "Base"))
            eval(@__MODULE__, :(const $(Symbol(mod)) = $mod))
        end
    end
    for statement in readlines("csv_precompile.jl")
        try
            Base.include_string(@__MODULE__, statement)
        catch
            # See julia issue #28808
            @info "failed to compile statement: $statement"
        end
    end
end # module

empty!(LOAD_PATH)
empty!(DEPOT_PATH)
```

After repeating the process of creating the object file and using a compiler to
create the shared library sysimage, we are in a position to time again:

```julia
julia> @time using CSV
  0.000408 seconds (665 allocations: 32.656 KiB)

julia> @time CSV.read("FL_insurance_sample.csv");
  0.031504 seconds (441 allocations: 37.383 KiB)

julia> @time CSV.read("FL_insurance_sample.csv");
  0.021355 seconds (423 allocations: 34.695 KiB)
```

And finally, our first time for parsing the CSV-file is close to the second time.

