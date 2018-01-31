# Julia AOT compiler

Helper script to build libraries and executables from Julia code.

```
usage: juliac.jl [-v] [-q] [-c] [-J <file>]
                 [--compile {yes|no|all|min}] [-C <target>]
                 [-O {0,1,2,3}] [-g {0,1,2}] [--inline {yes|no}]
                 [--check-bounds {yes|no}] [--math-mode {ieee,fast}]
                 [--depwarn {yes|no|error}] [-a] [-o] [-s] [-e] [-j]
                 [--version] [-h] juliaprog [cprog] [builddir]

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
  -a, --auto            automatically build required dependencies
  -o, --object          build object file
  -s, --shared          build shared library
  -e, --executable      build executable file
  -j, --julialibs       sync Julia libraries to builddir
  --version             show version information and exit
  -h, --help            show this help message and exit

examples:
  juliac.jl -vae hello.jl          # verbose, auto, build executable
  juliac.jl -vae hello.jl myprog.c # embed into user defined C program
  juliac.jl -qo hello.jl           # quiet, build object file only
  juliac.jl -vosej hello.jl        # build all and sync Julia libs
```

### Notes

1. The `juliac.jl` script uses the `ArgParse` package, make sure it is installed.

3. On Windows install `Cygwin` and the `mingw64-x86_64-gcc-core` package, see:\
   https://github.com/JuliaLang/julia/blob/master/README.windows.md

2. A shared library containing the system image `libhello.so`, and a
   driver binary `hello` are created in the `builddir` directory.
   Running `hello` produces the following output:

```
   $ ./hello
   hello, world
   f() = -0.37549581296986956
       ┌─────────────────────────────────────────────────┐
   100 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠎│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡰⠁⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⠊⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠔⠁⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠔⠁⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠤⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⠔⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠤⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⠤⠒⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡠⠔⠊⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       │⠀⠀⠀⠀⠀⠀⢀⣀⠤⠔⠊⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
     0 │⣀⠤⠤⠔⠒⠉⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│
       └─────────────────────────────────────────────────┘
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
sections in the Julia manual. Note that the name of the generated system image (`"libhello"` for `hello.jl`) is accessible from C in the preprocessor macro `JULIAC_PROGRAM_LIBNAME`.

With Julia 0.7, a single large binary can be created, which does not
require the driver program to load the shared library. An example of
that is in `program2.c`, where the image file is the binary itself.

For more information on embedding Julia see:\
https://github.com/JuliaLang/julia/blob/master/doc/src/manual/embedding.md
