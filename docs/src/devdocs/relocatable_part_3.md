# [Relocatable apps](@id man-tutorial-reloc)

In the previous tutorials, we created a custom sysimage and a binary (app) that
did some simple CSV parsing with an (depending on the exact demands) acceptable
latency (time until the app starts doing real work).  However, trying to send
this executable to another machine will fail spectacularly. This tutorial
outlines how to create and package a bundle of files into an app that we can
send to other machines and have them run, without for example, requiring Julia
itself to be installed, and without having to ship the source code of the app.

The tutorial will not deal with any kind of file size optimization or "tree
shaking" as it is sometimes called.

## Why is the built executable in the previous tutorial non-relocatable?

With relocatability, we mean the ability of being able to send e.g. an
executable (or a bundle of files including an executable, here called an app)
to another machine and have it run there without too many assumptions of the
state of the other machine. Relocatability is not an absolute measure, most
apps assume some properties of the machine they will run on (like graphics
drivers if one want to show graphics) but other (implicit) assumptions, like
embedding absolute paths into source code would make the app almost completely
non-relocatable since that absolute path is unlikely to exist on another
machine.  The goal here is to make our app relocatable enough such that if we
could install and run the same Julia as we use to build the app on the other
machine, then the app should also run on that machine (with exceptions if some
of our dependencies impose extra requirements on the machine).

So what is causing our executable that we built in the previous tutorial to not
be relocatable? Firstly, our sysimage relies on `libjulia` which we currently
load from the Julia directory and, in addition, `libjulia` itself relies on
other libraries (like LLVM) to work. And secondly, the packages we embedded in
the sysimage might have encoded assumptions about the current system into their
code.

The first problem is quite easy to fix while the second one is harder since
some popular packages that we might want to use as dependencies are inherently
non-relocatable.  There is nothing to do about that except try to fix these
packages.

For now, we will ignore the problem of packages not being relocatable by only
using a small dependency that we know does not have a relocatability problem.
Later in the blog post, we will revisit this and discuss more in-depth what
makes a package non-relocatable and how to fix this, even if the package needs
things like external libraries or binaries (spoiler alert: it is using the
artifact system presented in [the blog about
artifacts](https://julialang.org/blog/2019/11/artifacts).

## A toy app

The package we used in the previous examples to create a sysimage and
executable was CSV.jl. Now, to simplify things, we will only use a very simple
package with no relocatability problems that also has no dependencies. The
app will take some input on stdin and print it out with color to the terminal
using the [Crayons.jl](https://github.com/KristofferC/Crayons.jl) package.

When we add the Crayons.jl package we use a separate project to encapsulate
things better by creating a new project in the app directory:

```
~/MyApp
❯ julia -q --project=.

julia> using Pkg; Pkg.add("Crayons")
  Updating registry at `~/.julia/registries/General`
  Updating git-repo `https://github.com/JuliaRegistries/General.git`
 Resolving package versions...
  Updating `~/MyApp/Project.toml`
  [a8cc5b0e] + Crayons v4.0.1
  Updating `~/MyApp/Manifest.toml`
  [a8cc5b0e] + Crayons v4.0.1
```

The code for the app itself is quite simple:

```julia
module MyApp
using Crayons

Base.@ccallable function julia_main()::Cint
    try
        real_main()
    catch
        Base.invokelatest(Base.display_error, Base.catch_stack())
        return 1
    end
    return 0
end

function real_main()
    Crayons.FORCE_COLOR[] = true
    color = :red
    for arg in ARGS
        if !(arg in ["red", "green", "blue"])
            error("invalid color $arg")
        end
        color = Symbol(arg)
    end
    c = Crayon(foreground=color)
    r = Crayon(reset=true)
    while !eof(stdin)
        txt = String(readavailable(stdin))
        print(r, c, txt, r)
    end
    return 0
end
if abspath(PROGRAM_FILE) == @__FILE__
    real_main()
end
end # module
```

It got the same high-level structure as the previous app in the earlier parts.
The exact details are not so interesting but here a color is set based on the
command-line arguments and the `stdin` is written to `stdout` with that color.
We can see some usage of it:

![](app.png)


## Precompilation and sysimage

As in part 1 we generate precompilation statements and create a system image.
When recording precompilation statements and creating the sysimage, we make
sure to use the `--project` flag to use the packages declared in the local
project:

```
~/MyApp
❯ echo "Hello, this is some stdin" | julia --project --startup-file=no --trace-compile=app_precompile.jl MyApp.jl green
```

The `.o` file is then created with the same `generate_sysimage.jl` file as in part 2:

```
~/MyApp
❯ gcc -shared -o sys.so -Wl,--whole-archive sys.o -Wl,--no-whole-archive -L"/home/kc/julia/lib" -ljulia
```

And then the sysimage is linked:

```
~/MyApp
❯ gcc -shared -o sys.so -Wl,--whole-archive sys.o -Wl,--no-whole-archive -L"/home/kc/julia/lib" -ljulia
```

Before moving on and creating the executable, we need to think about what other
files we need for the app and the file structure we want.

## File structure for our app bundle

We already mentioned that `libjulia` has some dependencies.  Using `ldd`, we
can see the dependencies and where the dynamic linker would load them from:

```
~/julia/lib
❯ ldd libjulia.so
        linux-vdso.so.1 (0x00007ffec63c3000)
        libLLVM-6.0.so => /home/kc/julia/lib/./julia/libLLVM-6.0.so (0x00007f925ef13000)
        libdl.so.2 => /lib/x86_64-linux-gnu/libdl.so.2 (0x00007f925eeea000)
        librt.so.1 => /lib/x86_64-linux-gnu/librt.so.1 (0x00007f925eedf000)
        libpthread.so.0 => /lib/x86_64-linux-gnu/libpthread.so.0 (0x00007f925eebc000)
        libstdc++.so.6 => /home/kc/julia/lib/./julia/libstdc++.so.6 (0x00007f925eb3e000)
        libm.so.6 => /lib/x86_64-linux-gnu/libm.so.6 (0x00007f925e9ef000)
        libgcc_s.so.1 => /home/kc/julia/lib/./julia/libgcc_s.so.1 (0x00007f925e7d5000)
        libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f925e5e4000)
        /lib64/ld-linux-x86-64.so.2 (0x00007f9262356000)
```

So some libraries would be loaded from the (`libdl`, `librt`) system itself,
and some are bundled with Julia (`libLLVM`, `libstdc++` etc) in the `julia`
folder inside `lib`.  The reason the dynamic linker finds the libraries in the
subfolder is due to the `rpath` which can be seen with `objdump`:

```
❯ objdump -x libjulia.so |grep RPATH
  RPATH                $ORIGIN/julia:$ORIGIN
```

However, these are not the only libraries Julia (and its standard libraries)
need. Libraries can also be dynamically opened at runtime (with
[dlopen](https://linux.die.net/man/3/dlopen)).  For now, we will just bring all
the libraries in `lib/julia` along (excluding the sysimage since we will use
our sysimage).

The plan is that on macOS and Linux the files are structured as:

```
├── bin
│   └── MyApp [executable]
│   └── sys.so
└── lib
    ├── julia
    │   ├── libamd.so -> libamd.so.2.4.6
    │   ├── libamd.so.2 -> libamd.so.2.4.6
    │   ├── libamd.so.2.4.6
    │   ├── libcamd.so -> libcamd.so.2.4.6
   ... ...
    │   └── libz.so.1.2.11
    ├── libjulia.so -> libjulia.so.1.3
    ├── libjulia.so.1 -> libjulia.so.1.3
    └── libjulia.so.1.3
```

On Windows, we will just store everything in `bin` due to no convenient way of using `RPATH`.

We create a new folder `lib` and copy the libraries into it (and remove the
sysimage, since we will create cusom sysimage anyway):

```
~/MyApp
❯ mkdir lib

~/MyApp
❯ cp -r ~/julia/lib/ .

~/MyApp
❯ rm lib/julia/sys.so
```

## Creating the binary and the bundle

With some tweaks to the `rpath` entry so that the executable can find
`libjulia` the executable is created in the same way as in the previous tutorial.

```
~/MyApp
❯ gcc -DJULIAC_PROGRAM_LIBNAME=\"sys.so\" -o MyApp MyApp.c sys.so -O2 -I'/home/kc/julia/include/julia' -L'/home/kc/julia/lib' -fpie -Wl,-rpath,'$ORIGIN:$ORIGIN/../lib' -ljulia
```

We then finally move the executable and the sysimage to the `bin` folder:

```
~/MyApp
❯ mkdir bin

~/MyApp
❯ mv MyApp sys.so bin/
```

![](appexe.png)

The final bundle of our relocatable app is then created by putting the `bin`
and `lib` folders into an archive:


```
~/MyApp
❯ mkdir MyApp

~/MyApp
❯ cp bin/ lib/ MyApp

~/MyApp
❯ tar czvf MyApp.tar.gz MyApp
MyApp/
MyApp/bin/
MyApp/bin/MyApp
MyApp/bin/sys.so
MyApp/lib/
MyApp/lib/julia/
...
```

### macOS consideration

On macOS we need to run `install_name_tool` to make it use the `rpath` entries
which is done by executing:

```
install_name_tool -change sys.so @rpath/sys.so MyApp`
```


## Information about source code and build machine state stored in resulting app

It should be noted that there is some state from the machine where the sysimage
and binary is built that can be observed and the original source code.  Using
the [`strings`](https://linux.die.net/man/1/strings) application we can see what strings are embedded in
an executable or library.  Running it and grepping for some relevant substrings
we can see that a bunch of absolute paths are stored inside the sysimage:

```
~/MyApp/MyApp/lib/julia
❯ strings sys.so | grep /home/kc
/home/kc/.julia/packages/Crayons/P4fls/src/downcasts.jl
/home/kc/.julia/packages/Crayons/P4fls/src/crayon.jl
/home/kc/.julia/packages/Crayons/P4fls/src/crayon_stack.jl
/home/kc/MyApp/MyApp.jl
/home/kc/.julia/packages/Crayons/P4fls/src/Crayons.jl
/home/kc/.julia/packages/Crayons/P4fls/src/crayon_wrapper.jl
/home/kc/.julia/packages/Crayons/P4fls/src/test_prints.jl
/home/kc/.julia/packages/Crayons/P4fls/src/macro.jl
```

In addition, when we print the stacktrace upon failure in the main function,
we also leak absolute paths of the build machine:

```
~/MyApp
❯ MyApp/bin/MyApp purple
ERROR: invalid color purple
Stacktrace:
 [1] error(::String) at ./error.jl:33
 [2] real_main() at /home/kc/MyApp/MyApp.jl:20
 [3] julia_main() at /home/kc/MyApp/MyApp.jl:6
```

This could be avoided by not printing stacktraces and perhaps even binary
patching out the paths in the sysimage (not covered in this blog post).

The lowered code can also be read by loading the sysimage and using e.g. `@code_lowered`
on methods.

## Relocatability of Julia packages

The main problem with relocatability of Julia packages is that many packages
are encoding fundamentally non-relocatable information *into the source code*.
As an example, many packages tend to use a `build.jl` file (which runs when the
package is installed) that looks something like:

```julia
lib_path = find_library("libfoo")
write("deps.jl", "const LIBFOO_PATH = $(repr(lib_path))")
```

The main package file then contains

```julia
if !isfile("../build/deps.jl")
    error("run Pkg.build(\"Package\") to re-build Package")
end
include("../build/deps.jl")

function __init__()
    libfoo = Libdl.dlopen(LIBFOO_PATH)
end
```

The problem here is that `deps.jl` contains an absolute path to the library and
this gets encoded into the source code of the package. If we would store the
package in the sysimage and try use it on another system, it would error when
initialized since the `LIBFOO_PATH` variable is not valid on the other system.
However, sometimes we need to bundle libraries and data files since the package
uses them. Fortunately, there is a plan for that which can be seen in the [blog
post about artifacts](https://julialang.org/blog/2019/11/artifacts).

The idea is that with the new artifact system a file (`Artifacts.toml`), a
package can declaratively list external libraries and files that it needs.  In
addition, the artifact system provides a way to find these files at runtime in
a deterministic way. It is then possible to make sure that all artifacts needed
for the package is bundled in the app and can also be found by the package
during runtime.

The details are left out here since they become a bit technical but it should
give some incentive to switch to the artifact system.

