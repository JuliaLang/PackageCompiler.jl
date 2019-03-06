# PackageCompiler
[![Build Status](https://travis-ci.org/JuliaLang/PackageCompiler.jl.svg?branch=master)](https://travis-ci.org/JuliaLang/PackageCompiler.jl)

[![Coverage Status](https://coveralls.io/repos/JuliaLang/PackageCompiler.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/JuliaLang/PackageCompiler.jl?branch=master)

[![codecov.io](http://codecov.io/github/JuliaLang/PackageCompiler.jl/coverage.svg?branch=master)](http://codecov.io/github/JuliaLang/PackageCompiler.jl?branch=master)

Remove just-in-time compilation overhead from your package and compile it into a system image.

## Usage example

One can try ahead of time compiled images online with nextjournal!
Here are some images for a few popular packages:

[dataframes + query](https://nextjournal.com/sdanisch/data-remix)

[plots & gr backend](https://nextjournal.com/sdanisch/plots-remix)

[makie & opengl backend](https://nextjournal.com/sdanisch/glmakie-remix)

[makie & cairo backend](https://nextjournal.com/sdanisch/cairomakie-remix)

If you find a package to be missing, anyone can create these images and share them here! 
One can also download the docker images for local usage:
[instructions](https://nextjournal.com/sdanisch/static-cairomakie)

(signup code for nextjournal: `julia1.0`)


# compile_package
```Julia
using PackageCompiler

# This command will use the `runtest.jl` of `ColorTypes` + `FixedPointNumbers` to find out what functions to precompile!
# `force = false` to not force overwriting Julia's current system image
compile_package("ColorTypes", "FixedPointNumbers", force = false) 

# force = false is the default and recommended, since overwriting your standard system image can make Julia unusable.

# If you used force and want your old system image back (force will overwrite the default system image Julia uses) you can run:
revert()

```

# compile_incremental

This function works like the above, but incrementally adds the newly cached binary to your old system image.
That means that all precompiled code in the system image (e.g. REPL code) is preserved and therefore one gets a lag free start of the Julia REPL.
Also, the compilation times are much faster:

help?> compile_incremental
```
compile_incremental(
    toml_path::String, snoopfile::String;
    force = false, precompile_file = nothing, verbose = true,
    debug = false, cc_flags = nothing
)

Extract all calls from `snoopfile` and ahead of time compiles them
incrementally into the current system image.
`force = true` will replace the old system image with the new one.
The argument `toml_path` should contain a project file of the packages that `snoopfile` explicitly uses.
Implicitly used packages & modules don't need to be contained!

To compile just a single package, see the simpler version  `compile_incremental(package::Symbol)`:
```

```
compile_incremental(
    packages::Symbol...;
    force = false, reuse = false, verbose = true,
    debug = false, cc_flags = nothing
)

Incrementally compile `package` into the current system image.
`force = true` will replace the old system image with the new one.
`compile_incremental` will run the `Package/test/runtests.jl` file to
record the functions getting compiled. The coverage of the Package's tests will
thus determine what is getting ahead of time compiled.
For a more explicit version of compile_incremental, see:
`compile_incremental(toml_path::String, snoopfile::String)`
```
  

# more functionality

```julia
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


# Static Julia Compiler

Build shared libraries and executables from Julia code.

Run `juliac.jl -h` for help:

```
usage: juliac.jl [-v] [-q] [-d <dir>] [-n <name>] [-p <file>] [-c]
                 [-a] [-o] [-s] [-i] [-e] [-t] [-j] [-f <file>] [-r]
                 [-R] [-J <file>] [-H <dir>] [--startup-file {yes|no}]
                 [--handle-signals {yes|no}]
                 [--sysimage-native-code {yes|no}]
                 [--compiled-modules {yes|no}]
                 [--depwarn {yes|no|error}]
                 [--warn-overwrite {yes|no}]
                 [--compile {yes|no|all|min}] [-C <target>]
                 [-O {0,1,2,3}] [-g <level>] [--inline {yes|no}]
                 [--check-bounds {yes|no}] [--math-mode {ieee,fast}]
                 [--cc <cc>] [--cc-flag <flag>] [--version] [-h]
                 juliaprog [cprog]

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
  -i, --init-shared     add `init_jl_runtime` and `exit_jl_runtime` to
                        shared library for runtime initialization
  -e, --executable      build executable file
  -t, --rmtemp          remove temporary build files
  -j, --copy-julialibs  copy Julia libraries to build directory
  -f, --copy-file <file>
                        copy file to build directory, can be repeated
                        for multiple files
  -r, --release         build in release mode, implies `-O3 -g0`
                        unless otherwise specified
  -R, --Release         perform a fully automated release build,
                        equivalent to `-atjr`
  -J, --sysimage <file>
                        start up with the given system image file
  -H, --home <dir>      set location of `julia` executable
  --startup-file {yes|no}
                        load `~/.julia/config/startup.jl`
  --handle-signals {yes|no}
                        enable or disable Julia's default signal
                        handlers
  --sysimage-native-code {yes|no}
                        use native code from system image if available
  --compiled-modules {yes|no}
                        enable or disable incremental precompilation
                        of modules
  --depwarn {yes|no|error}
                        enable or disable syntax and method
                        deprecation warnings
  --warn-overwrite {yes|no}
                        enable or disable method overwrite warnings
  --compile {yes|no|all|min}
                        enable or disable JIT compiler, or request
                        exhaustive compilation
  -C, --cpu-target <target>
                        limit usage of CPU features up to <target>
                        (implies default `--sysimage-native-code=no`)
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
  --cc <cc>             system C compiler
  --cc-flag <flag>      pass custom flag to the system C compiler when
                        building a shared library or executable, can
                        be repeated for multiple flags
  --version             show version information and exit
  -h, --help            show this help message and exit

examples:
  juliac.jl -vae hello.jl        # verbose, build executable and deps
  juliac.jl -vae hello.jl prog.c # embed into user defined C program
  juliac.jl -qo hello.jl         # quiet, build object file only
  juliac.jl -vosej hello.jl      # build all and copy Julia libs
  juliac.jl -vRe hello.jl        # fully automated release build
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
   folder (`normpath(Base.find_package("PackageCompiler"), "..", "..")`).

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

## Side effects

1.  Using `PackageCompiler` makes it impossible to load changed package code automatically - it must be `eval`'ed in from the current session.  This becomes a problem when developing packages.
