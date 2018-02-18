# PackageCompiler
[![Build Status](https://travis-ci.org/SimonDanisch/PackageCompiler.jl.svg?branch=master)](https://travis-ci.org/SimonDanisch/PackageCompiler.jl)

[![Coverage Status](https://coveralls.io/repos/SimonDanisch/PackageCompiler.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/SimonDanisch/PackageCompiler.jl?branch=master)

[![codecov.io](http://codecov.io/github/SimonDanisch/PackageCompiler.jl/coverage.svg?branch=master)](http://codecov.io/github/SimonDanisch/PackageCompiler.jl?branch=master)

Remove jit overhead from your package and compile it into a system image.

## Usage example
E.g. do:
```Julia
using PackageCompiler

# This command will use the runtest.jl of Matcha + UnicodeFun to find out what functions to precompile!
# force = false to not force overwriting julia's current system image
compile_package("Matcha", "UnicodeFun", force = false, reuse = false)

# build again, reusing the snoop file
compile_package("Matcha", "UnicodeFun", force = false, reuse = true)

# You can define a file that will get run for snooping explicitly like this:
# this makes sure, that binary gets cached for all functions called in `for_snooping.jl`
compile_package("Matcha", "relative/path/for_snooping.jl")

# if you used force and want your old system image back (force will overwrite the default system image Julia uses) you can run:
revert()

# Or if you simply want to get a native system image e.g. when you have downloaded the generic Julia install:
build_native_image()

# building an executable

build_executable(
    "hello.jl", # julia file containing a julia main, e.g. like examples/hello.jl
    snoopfile = "call_functions.jl", # julia file that calls functions that you want to make sure to have precompiled [optional]
    builddir = "folder/you/want/the/build/artifacts" # that's where hello.exe will end up
)
```


## Troubleshooting:

- You might need to tweak your runtest, since SnoopCompile can have problems with some statements. Please open issues about concrete problems! This is also why there is a way to point to a file different from runtests.jl, for the case it becomes impossible to combine testing and snoop compiling (just pass `("package", "snoopfile.jl")`)!

- non const globals are problematic, or globals defined in functions - removing those got me to 95% of making the package safe for static compilation

- type unstable code had some inference issues (around 2 occurrence, where I’m still not sure what was happening) - both cases happened with dictionaries… Only way to find those was investigating the segfaults with `gdb`, but then it was relatively easy to just juggle around the code, since the stacktraces accurately pointed to the problem. The non const globals might be related since they introduce type instabilities.

- some generated functions needed reordering of the functions they call ( actually, even for normal compilation, all functions that get called in a generated function should be defined before it)

- I uncovered one out of bounds issue, that somehow was not coming up without static-compilation
- I used julia-debug to uncover most bugs, but actually, the last errors I was trying to uncover where due to using julia-debug!

- you’re pretty much on your own and need to use gdb to find the issues and I still don’t know what the underlying julia issues are and when they will get fixed :wink: See: https://github.com/JuliaLang/julia/issues/24533. Hopefully we look at a better story with Julia 1.0!


# Static Julia Compiler


Building shared libraries and executables from Julia code.

Run `juliac.jl -h` for help:

```
usage: juliac.jl [-v] [-q] [-c] [-J <file>]
                 [--compile {yes|no|all|min}] [-C <target>]
                 [-O {0,1,2,3}] [-g {0,1,2}] [--inline {yes|no}]
                 [--check-bounds {yes|no}] [--math-mode {ieee,fast}]
                 [--depwarn {yes|no|error}] [-a] [-o] [-s] [-e] [-j]
                 [--version] [-h] juliaprog [cprog] [builddir]

Static Julia Compiler

positional arguments:
  juliaprog             Julia program to compile
  cprog                 C program to compile (required only when
                        building an executable; if not provided a
                        minimal standard program is used)
  builddir              build directory, either absolute or relative
                        to the Julia program directory (default:
                        "builddir")

optional arguments:
  -v, --verbose         increase verbosity
  -q, --quiet           suppress non-error messages
  -c, --clean           delete builddir
  -J, --sysimage <file>
                        start up with the given system image file
  --compile {yes|no|all|min}
                        enable or disable JIT compiler, or request
                        exhaustive compilation
  -C, --cpu-target <target>
                        limit usage of CPU features up to <target>
  -O, --optimize {0,1,2,3}
                        set optimization level (type: Int64)
  -g {0,1,2}            set debugging information level (type: Int64)
  --inline {yes|no}     control whether inlining is permitted
  --check-bounds {yes|no}
                        emit bounds checks always or never
  --math-mode {ieee,fast}
                        set floating point optimizations
  --depwarn {yes|no|error}
                        set syntax and method deprecation warnings
  -a, --autodeps        automatically build required dependencies
  -o, --object          build object file
  -s, --shared          build shared library
  -e, --executable      build executable file
  -j, --julialibs       sync Julia libraries to builddir
  --version             show version information and exit
  -h, --help            show this help message and exit

examples:
  juliac.jl -vae hello.jl        # verbose, build executable and deps
  juliac.jl -vae hello.jl prog.c # embed into user defined C program
  juliac.jl -qo hello.jl         # quiet, build object file only
  juliac.jl -vosej hello.jl      # build all and sync Julia libs
```

### Notes

1. The `juliac.jl` script is located in the PackageCompiler root folder (Pkg.dir("PackageCompiler"))

2. A shared library containing the system image `libhello.so`, and a
   driver binary `hello` are created in the `builddir` directory.
   Running `hello` produces the following output:

```
   $ ./hello
   hello, world
   sin(0.0) = 0.0
         ┌────────────────────────────────────────┐
       1 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠔⠉⠉⠉⠉⠉⠒⢄⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         │⠀⠀⠀⠀⠀⠀⠀⠀⢠⠔⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠑⢄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         │⠀⠀⠀⠀⠀⠀⠀⡔⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠱⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         │⠀⠀⠀⠀⠀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠢⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         │⠀⠀⠀⢀⠎⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         │⠀⠀⡠⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠣⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         │⠀⡔⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠑⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         │⠮⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠤⠬⢦⠤⠤⠤⠤⠤⠤⠤⠄│
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠣⡀⠀⠀⠀⠀⠀⠀│
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⢄⠀⠀⠀⠀⠀│
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢢⠀⠀⠀⠀│
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠑⢄⠀⠀│
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠣⡀│
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈│
      -1 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
         └────────────────────────────────────────┘
         1                                       10

```

## Under the hood

The `juliac.jl` script uses the `--output-o` switch to compile the user
script into object code, and then builds it into the system image
specified by the `-J` switch. This prepares an object file, which is
then linked into a shared library containing the system image and user
code. A driver script such as the one in `program.c` can then be used to
build a binary that runs the julia code.

Instead of a driver script, the generated system image can be embedded
into a larger program following the embedding examples and relevant
sections in the Julia manual. Note that the name of the generated system
image (`"libhello"` for `hello.jl`) is accessible from C in the
preprocessor macro `JULIAC_PROGRAM_LIBNAME`.

With Julia 0.7, a single large binary can be created, which does not
require the driver program to load the shared library. An example of
that is in `program2.c`, where the image file is the binary itself.

For more information on static Julia compilation see:\
https://juliacomputing.com/blog/2016/02/09/static-julia.html

For more information on embedding Julia see:\
https://github.com/JuliaLang/julia/blob/master/doc/src/manual/embedding.md
