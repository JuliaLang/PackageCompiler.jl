# Overview

## Steps:
  1. Build julia from source
  1. Installing llvm-cbe
  1. Generate julia output `.bc` file with `--compile=all`
  1. Convert julia output `.bc` –> `.ll`, `.c`, `.o`, `.dylib` / `.so` / `.dll`
  1. Build standalone applications

Start by defining the directory of the julia src root folder where you have previously built an (unmodified) version of julia master (&ge;v0.5-):

    JULIA_ROOT = `pwd`/julia

# Install / compile llvm-cbe

Or see instructions on github repo: https://github.com/JuliaComputing/llvm-cbe

    # Build LLVM 3.7, for example, here we build it in-tree
    make -C $JULIA_ROOT/deps compile-llvm LLVM_VER=3.7.0

    # installs llvm-cbe to $JULIA_ROOT/deps/build/llvm-3.7.0/build_Release/Release/bin
    git clone git@github.com:JuliaComputing/llvm-cbe.git $JULIA_ROOT/deps/srccache/llvm-3.7.0/projects/llvm-cbe
    make -C $JULIA_ROOT/deps/build/llvm-3.7.0/build_Release/projects

# Generate the statically-compiled Julia object file

These are equivalent to the `make julia-sysimg` target,
with the addition of a `--compile=all` flag.
Choose one, or make your own from the examples:


    # build a bare-bones sysimg named `inference0.bc`
    # containing only `Core.Inference`, as defined by `coreimg.jl`:
    pushd $JULIA_ROOT/base
    $JULIA_ROOT/usr/bin/julia --compile=all \
        --output-bc inference0.bc \
        coreimg.jl
    popd

    # build a bare-bones sysimg containing only `Core.Inference`,
    # but starting from an existing inference image for better type information:
    pushd $JULIA_ROOT/base
    $JULIA_ROOT/usr/bin/julia --compile=all \
        --sysimg $JULIA_ROOT/usr/lib/julia/inference.ji \
        --output-bc inference.bc \
        coreimg.jl
    popd

    # build a regular julia sysimg, but with all functions statically compiled
    pushd $JULIA_ROOT/base
    $JULIA_ROOT/usr/bin/julia --compile=all \
        --sysimg $JULIA_ROOT/usr/lib/julia/inference.ji \
        --output-bc sys.bc \
        sysimg.jl
    popd

    # starting from any existing sysimg,
    # add the user code "program.jl" and statically compile everything
    $JULIA_ROOT/usr/bin/julia --startup-file=no --compile=all --precompiled=no \
        --sysimg $JULIA_ROOT/usr/lib/julia/sys.dylib \
        --output-bc sys-plus.bc \
        program.jl

Note that since Julia specializes its code based on the host operating system
(much like `#define` in a C-preprocessor),
the resulting source files should not be considered to be portable to
other operating systems or word sizes.

# Conversion to source files

The above output files are compressed bitcode,
but can be easily exported to human-readable
text in any one of several source code formats.

## Convert to llvm assembly file (`.ll`)
    $JULIA_ROOT/usr/bin/llvm-dis sys-plus.bc

## Convert to C source file (`.c`)
    $JULIA_ROOT/deps/build/llvm-3.7.0/build_Release/Release/bin/usr/bin/llvm-cbe \
        sys-plus.bc

## Compile to native assembly file (`.S`)
    $JULIA_ROOT/usr/bin/llc -filetype=asm sys-plus.bc

# Compilation to native machine code

To use this code, any of the above source inputs can be
compiled into a native object file.
Below are some sample commands for common compiler invocations.

Whenever `.so`, is used below,
replace with the appropriate file extension for your OS:
* Darwin: `.dylib`
* Windows: `.dll`
* Linux/other: `.so`
* or choose Static Linking (any OS): `.a`


 These samples are intended only as examples of a minimal command line.
 It is expected that you will want to customize it to suit your application.

## LLVM Compiler (llc) Commands
`.bc` / `.ll` –> `.o` –> `.so`

    # Compile llvm file to native object file
    $JULIA_ROOT/usr/bin/llc -filetype=obj sys-plus.bc -o=$JULIA_ROOT/usr/lib/julia/sys-plus.o

    # Link object file against libjulia and libjulia-debug
    pushd $JULIA_ROOT
    cp usr/lib/julia/sys-plus.o usr/lib/julia/sys-plus-debug.o
    make `pwd`/usr/lib/julia/sys-plus.so
    make `pwd`/usr/lib/julia/sys-plus-debug.so
    popd

## Clang/GCC Compiler Commands
`.c` –> `.o` –> `.so`

    # Compile output from C to `.o` format, with most compiler warnings enabled
    WARN='-std=c99 -pedantic -Wall -Wextra -Wno-unused-variable -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare -Wno-unused-but-set-variable -Wno-long-long -Wno-invalid-noreturn'
    cc -c -fPIC sys-plus.cbe.c ${WARN} -o sys-plus.cbe.o -I$JULIA_ROOT/src -I$JULIA_ROOT/src/support -pipe -finline-functions -g -O0

    # emit as a dynamic library
    cc -shared sys-plus.cbe.o  -o sys-plus.cbe.so -L$JULIA_ROOT/usr/lib -ljulia ${WARN}
    install_name_tool -id @rpath/sys-plus.cbe.so sys-plus.cbe.so # Darwin only

    # or emit as a static library
    ar rcs sys-plus.cbe.a sys-plus.cbe.o

## MSVC Compiler Command
`.c` –> `.o` –> `.dll`

Run these from the vcvars32.bat command prompt.
(Tested with Microsoft Visual C++ 2010 Tools)

    # for x86, add `/D__unaligned=` to the command below
    cl /c sys-plus.cbe.c /Fosys-plus.cbe.obj /I%JULIA_ROOT%\src /I%JULIA_ROOT%\src\support /Wall /wd4054 /wd4245 /wd4100 /wd4055 /wd4127 /wd4645 /wd4646 /wd4389 /wd4242 /wd4146 /wd4244 /wd4820 /wd4702 /Zi

    # emit as a dynamic library, linked with libjulia, libopenlibm, and msvcrt
    link /dll sys-plus.cbe.obj /out:sys-plus.cbe.dll %JULIA_ROOT%\usr\lib\libjulia.dll.a %JULIA_ROOT%\usr\lib\libopenlibm.a msvcrt.lib /nodefaultlib:libcmt /nodefaultlib:libcpmt /nodefaultlib:oldnames /debug

# Build libjulia sans codegen support
Setting `JULIACODEGEN=` during `make` disables linking of `libLLVM` into `libjulia`.
Any attempt to use the JIT or code-generation at runtime
with the resulting library will throw a Julia exception.

    make JULIACODEGEN=none

    # demonstrate that LLVM support is removed gone by checking
    # - much smaller size: `du %JULIA_ROOT%/usr/lib/libjulia.so`
    # - no llvm symbols: `nm %JULIA_ROOT%/usr/lib/libjulia.so`
    # - disabled JIT: `%JULIA_ROOT%/usr/bin/julia` fails to run

# Run
To use this code, explicitly disable runtime code generation via the `--compile=no` flag
and load using the generic Julia binary:

    $JULIA_ROOT/usr/bin/julia --sysimg=$JULIA_ROOT/usr/lib/julia/sys-plus.dylib --compile=no --precompiled=yes

# Create custom embedded app
It is also possible to create a native wrapper around the shared (or static) library.

On the Julia side, it is often useful to declare functions to export to C (for example, in the `program.jl` file):

    Base.ccallable(func_to_export, Tuple{CFunction, Signature}, "c_decl_name")
    @ccallable function func_to_export2(sig::Bits) end

The type signature translation for declaration at the top of your `.c` file
is the same as for `ccall` / `cfunction`:

    extern return_type (*c_decl_name)(cfunction, signature);
    extern return_type2 (*func_to_export2)(bits);

The compiler command line is similar to the earlier versions.
The following are example invocations of the compiler
and linker for the sample code `program.c` and `program2.c`.
Substitute your application-specific flags here, as appropriate.

    CFLAGS="$WARN -I$JULIA_ROOT/src -I$JULIA_ROOT/src/support -I$JULIA_ROOT/usr/include -ggdb3"
    LDFLAGS="-L$JULIA_ROOT/usr/lib -Wl,-rpath,`pwd`/usr/lib"
    LIBS="-ljulia"

    cc program.c -o julia_hello $CFLAGS $LDFLAGS $JULIA_ROOT/usr/lib/julia/sys-plus.so $LIBS
    ./julia_hello

    cc program2.c -o program2 $CFLAGS $LDFLAGS program.a $LIBS
    ./program2 arg1 arg2 "arg 3"


# Known compiler warnings:

> MSVC doesn't have a prototype for some libm functions (like pow).

Possible solution: use openlibm.h header instead of math.h
