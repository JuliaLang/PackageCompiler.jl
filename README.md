## Building a shared library and executable from your julia code

1. Make sure all the packages and modules are precompiled. In my case
   the Julia 0.6 binary is downloaded and installed in `~/julia-0.6`.

2. Clone this repo and use the `juliac.jl` script. The way to call it is as follows:

   Usage: `juliac.jl <Julia Program file>`

   In my case, I invoke it for `hello.jl` as follows. Make sure that the driver program
   is also in the `static-julia` directory: `~/julia-0.6/bin/julia juliac.jl hello.jl`

   Note: `hello.jl` does not need to be in the `static-julia` directory.

3. A shared library containing the system image `libhello.so`, and a
   driver binary `hello` are created in the `builddir` directory.
```
   $ ./hello
   hello, world
   f() = -0.37549581296986956
```
   The plot command in `hello.jl` is only meant to exercise a bunch of Gadfly compilation.
   It is not expected to produce a plot in the terminal.

## Under the hood

The `juliac.jl` script uses the `--output-o` switch to compile the user
script into object code, and then builds it into the system image
specified by the `-J` switch. This prepares an object file, which is
then linked into a shared library containing the system image and user
code. A driver script such as the one in `program.c` can then be used to
build a binary that runs the julia code. For now, the image file has
to be changed in `program.c` to match the name of the shared library
containing the compiled julia program.

Instead of a driver script, the generated system image can be embedded
into a larger program following the embedding examples and relevant
sections in the Julia manual.

With Julia 0.7, a single large binary can be created, which does not
require the driver program to load the shared library. An example of
that is in `program2.c`, where the image file is the binary itself.

