# PackageCompiler
[![Build Status](https://travis-ci.org/JuliaLang/PackageCompiler.jl.svg?branch=master)](https://travis-ci.org/JuliaLang/PackageCompiler.jl)

[![Coverage Status](https://coveralls.io/repos/JuliaLang/PackageCompiler.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/JuliaLang/PackageCompiler.jl?branch=master)

[![codecov.io](http://codecov.io/github/JuliaLang/PackageCompiler.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaLang/PackageCompiler.jl?branch=master)

Remove just-in-time compilation overhead from your package and compile it into a system image.

## Usage example
E.g. do:

```Julia
using PackageCompiler

# This command will use the runtest.jl of Matcha + UnicodeFun to find out what functions to precompile!
# `force = false` to not force overwriting Julia's current system image
compile_package("Matcha", "UnicodeFun", force = false, reuse = false)

# Build again, reusing the snoop file
compile_package("Matcha", "UnicodeFun", force = false, reuse = true)

# You can define a file that will get run for snooping explicitly like this:
# this makes sure, that binary gets cached for all functions called in `for_snooping.jl`
compile_package("Matcha", "relative/path/for_snooping.jl")

# If you used force and want your old system image back (force will overwrite the default system image Julia uses) you can run:
revert()

# Or if you simply want to get a native system image e.g. when you have downloaded the generic Julia install:
force_native_image!()

# Build an executable
build_executable(
    "hello.jl", # Julia script containing a `julia_main` function, e.g. like `examples/hello.jl`
    snoopfile = "call_functions.jl", # Julia script which calls functions that you want to make sure to have precompiled [optional]
    builddir = "path/to/builddir" # that's where the compiled artifacts will end up [optional]
)

# Build a shared library
build_shared_lib("hello.jl")
```

## Troubleshooting:

- You might need to tweak your runtest, since `SnoopCompile` can have problems
with some statements. Please open issues about concrete problems! This is also
why there is a way to point to a file different from `runtests.jl`, for the case
it becomes impossible to combine testing and snoop compiling, just pass
`("package", "snoopfile.jl")`!

- Non constant globals and globals defined in functions are problematic.
Removing those got me to 95% of making the package safe for static compilation.

- Type unstable code had some inference issues (around 2 occurrence, where I’m
still not sure what was happening, and both cases happened with dictionaries).
The only way to find those was investigating the segfaults with `gdb`, but then
it was relatively easy to just juggle around the code, since the stacktraces
accurately pointed to the problem. The non constant globals might be related
since they introduce type instabilities.

- Some generated functions needed reordering of the functions they call
(actually, even for normal compilation, all functions that get called in a
generated function should be defined before it).

- I uncovered one out-of-bounds issue, that somehow was not coming up without
static compilation.

- I used `julia-debug` to uncover most bugs, but actually the last errors I was
trying to uncover where due to `julia-debug` itself!

- You’re pretty much on your own and need to use `gdb` to find any issues and I
still don’t know what the underlying julia issues are and when they will get
fixed :wink: See: https://github.com/JuliaLang/julia/issues/24533.
Hopefully we'll look at a better story with Julia 1.0!


# Static Julia Compiler

Build shared libraries and executables from Julia code.

Run `juliac.jl -h` for help:

```
usage: juliac.jl [-v] [-q] [-d <dir>] [-n <name>] [-p <file>] [-c]
                 [-a] [-o] [-s] [-e] [-t] [-j] [-f <file>] [-r] [-R]
                 [-J <file>] [--precompiled {yes|no}]
                 [--compilecache {yes|no}] [-H <dir>]
                 [--startup-file {yes|no}] [--handle-signals {yes|no}]
                 [--compile {yes|no|all|min}] [-C <target>]
                 [-O {0,1,2,3}] [-g <level>] [--inline {yes|no}]
                 [--check-bounds {yes|no}] [--math-mode {ieee,fast}]
                 [--depwarn {yes|no|error}] [--cc <cc>]
                 [--cc-flags <flags>] [--version] [-h] juliaprog
                 [cprog]

Static Julia Compiler

positional arguments:
  juliaprog             Julia program to compile
  cprog                 C program to compile (required only when
                        building an executable, if not provided a
                        minimal driver program is used)

optional arguments:
  -v, --verbose         increase verbosity
  -q, --quiet           suppress non-error messages
  -d, --builddir <dir>  build directory
  -n, --outname <name>  output files basename
  -p, --snoopfile <file>
                        specify script calling functions to precompile
  -c, --clean           remove build directory
  -a, --autodeps        automatically build required dependencies
  -o, --object          build object file
  -s, --shared          build shared library
  -e, --executable      build executable file
  -t, --rmtemp          remove temporary build files
  -j, --copy-julialibs  copy Julia libraries to build directory
  -f, --copy-file <file>
                        copy file to build directory, can be repeated
                        for multiple files
  -r, --release         build in release mode, implies `-O3 -g0`
                        unless otherwise specified
  -R, --Release         perform a fully automated release build,
                        equivalent to `-caetjr`
  -J, --sysimage <file>
                        start up with the given system image file
  --precompiled {yes|no}
                        use precompiled code from system image if
                        available
  --compilecache {yes|no}
                        enable/disable incremental precompilation of
                        modules
  -H, --home <dir>      set location of `julia` executable
  --startup-file {yes|no}
                        load ~/.juliarc.jl
  --handle-signals {yes|no}
                        enable or disable Julia's default signal
                        handlers
  --compile {yes|no|all|min}
                        enable or disable JIT compiler, or request
                        exhaustive compilation
  -C, --cpu-target <target>
                        limit usage of CPU features up to <target>
                        (implies default `--precompiled=no`)
  -O, --optimize {0,1,2,3}
                        set the optimization level (type: Int64)
  -g, --debug <level>   enable / set the level of debug info
                        generation (type: Int64)
  --inline {yes|no}     control whether inlining is permitted
  --check-bounds {yes|no}
                        emit bounds checks always or never
  --math-mode {ieee,fast}
                        disallow or enable unsafe floating point
                        optimizations
  --depwarn {yes|no|error}
                        enable or disable syntax and method
                        deprecation warnings
  --cc <cc>             system C compiler
  --cc-flags <flags>    pass custom flags to the system C compiler
                        when building a shared library or executable
  --version             show version information and exit
  -h, --help            show this help message and exit

examples:
  juliac.jl -vae hello.jl        # verbose, build executable and deps
  juliac.jl -vae hello.jl prog.c # embed into user defined C program
  juliac.jl -qo hello.jl         # quiet, build object file only
  juliac.jl -vosej hello.jl      # build all and copy Julia libs
  juliac.jl -vR hello.jl         # fully automated release build
```

## Building a shared library
`PackageCompiler` can compile a julia library into a linkable shared library,
built for a specific architecture, with a `C`-compatible ABI which can be
linked against from another program. This can be done either from the julia
api, `build_shared_lib("src/HelloLib.jl", "hello")`, or on the command line,
`$ juliac.jl -vas src/HelloLib.jl`. This will generate a shared library called
`builddir/libhello.{so,dylib,dll}` depending on your system.

The provided julia file, `src/HelloLib.jl`, is `PackageCompiler`'s entry point
into the library, so it should be the "top level" library file. Any julia code
that it `include`s or `import`s will be compiled into the shared library.

Note that for a julia function to be callable from `C`, it must be defined with
`Base.@ccallable`, e.g. `Base.@ccallable foo()::Cint = 3`.

## Building an executable
To compile a Julia program into an executable, you can use either the julia
api, `build_executable("hello.jl", "hello")`, or the command line, `$
juliac.jl -vae hello.jl`.

The provided julia file, `hello.jl`, is `PackageCompiler`'s entry point into the
program, and should be the program's "main" file. Any julia code that it
`include`s or `import`s will be compiled into the shared library, which will be
linked against the provided `C` program to create an executable at
`builddir/hello`.

If you choose to use the default `C` program, your julia code _must_ define
`julia_main` as its entry point. The resultant executable will start by calling
that function, so all of your program's logic should proceed from that
function. For example:

```
Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    hello_main(ARGS)  # call your program's logic.
    return 0
end
```

Please see
[examples/hello.jl](https://github.com/JuliaLang/PackageCompiler.jl/blob/master/examples/hello.jl)
for an example Julia program.

### Notes

1. The `juliac.jl` script is located in the `PackageCompiler` root
   folder (`Pkg.dir("PackageCompiler")`).

2. A shared library containing the system image `hello.so`, and a
   driver binary `hello` are created in the `builddir` directory.
   Running `hello` produces the following output:

```
   hello, world
   sin(0.0) = 0.0
      ┌─────────────────────────────────────────────────┐
    1 │⠀⠀⠀⠀⠀⠀⠀⡠⠊⠉⠉⠉⠢⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      │⠀⠀⠀⠀⠀⢠⠎⠀⠀⠀⠀⠀⠀⠘⢆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      │⠀⠀⠀⠀⢠⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠳⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      │⠀⠀⠀⢠⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠱⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      │⠀⠀⢠⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠳⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      │⠀⢀⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢣⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      │⠀⡎⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
      │⠼⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠬⢦⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⢤│
      │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⡆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠇│
      │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡎⠀│
      │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠱⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡞⠀⠀│
      │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠱⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡜⠀⠀⠀│
      │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠱⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡞⠀⠀⠀⠀│
      │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⢆⠀⠀⠀⠀⠀⠀⢠⠎⠀⠀⠀⠀⠀│
   -1 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠑⢄⣀⣀⣀⠔⠁⠀⠀⠀⠀⠀⠀│
      └─────────────────────────────────────────────────┘
      0                                               100
```

3. Currently, before another program can call any of the functions defined in
   the created shared library, that program must first initialize the julia
   runtime. (See
   [#53](https://github.com/JuliaLang/PackageCompiler.jl/issues/53) for
   details.)


## Under the hood

The `juliac.jl` script uses the `--output-o` switch to compile the user
script into object code, and then builds it into the system image
specified by the `-J` switch. This prepares an object file, which is
then linked into a shared library containing the system image and user
code. A driver script such as the one in `program.c` can then be used
to build a binary that runs the Julia code.

Instead of a driver script, the generated system image can be embedded
into a larger program, see the
[Embedding Julia](https://docs.julialang.org/en/stable/manual/embedding/)
section of the Julia manual. Note that the name of the generated system
image (`"libhello"` for `hello.jl`) is accessible from C in the
preprocessor macro `JULIAC_PROGRAM_LIBNAME`.

For more information on static Julia compilation see:\
https://juliacomputing.com/blog/2016/02/09/static-julia.html
