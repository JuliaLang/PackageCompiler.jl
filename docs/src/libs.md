# [Libraries](@id libraries)

Creating a library with PackageCompiler involves creating a custom system image with a couple of
additional features to facilitate linking and use by external (non-Julian) programs--it's already
a dynamic library.

As with app creation, we distribute all of the libraries necessary to run Julia. In the end, we
end up with a directory of libraries (`lib`, or `bin` on Windows), an `include` directory
with C header files, and an `artifacts` directory (for any additional library artifacts needed
by the Julia runtime).

Of course, we also want the library to be relocatable, and all of the caveats
in the [App relocatability](@ref relocatability) section still apply.

## Creating a library

As with apps, the source of a library is a package with a project and manifest file.
The library is expected to provide C-callable functions for the functionality it
is providing, defined using the `Base.@ccallable` macro:

```julia
function increment(count::Cint)::Cint
    count += 1
    println("Incremented count: $count")
    return count
end
```

All C-callable functions will be exported and made available to programs that link to the 
library.

A skeleton of a library to start working from can be found 
[here](https://github.com/JuliaLang/PackageCompiler.jl/tree/master/examples/MyLib).

A complete example that works on all supported 64-bit OS platforms can be found [here](https://github.com/simonbyrne/libcg).
(32-bit is not yet working there).

The library is compiled using the [`create_library`](@ref) function, which takes the path to the
source code and the destination directory. 

```
~/PackageCompiler.jl/examples
❯ julia -q --project

julia> using PackageCompiler

julia> create_library("MyLib", "MyLibCompiled";
                      lib_name="libinc",
                      precompile_execution_file="MyLib/build/generate_precompile.jl",
                      precompile_statements_file="MyLib/build/additional_precompile.jl",
                      header_files = ["MyLib/build/mylib.h"])
└ @ PackageCompiler ~/.julia/dev/PackageCompiler/src/PackageCompiler.jl:903
[ Info: PackageCompiler: creating base system image (incremental=false)...
[ Info: PackageCompiler: creating system image object file, this might take a while...
[ Info: PackageCompiler: creating system image object file, this might take a while...

julia> exit()

~/PackageCompiler.jl/examples
❯ ls -al MyLibCompiled/lib/libinc.*
-rwxr-xr-x  1 kmsquire  staff  97241152 Jan 28 14:27 MyLibCompiled/lib/libinc.dylib

~/PackageCompiler.jl/examples
❯ ls MyLibCompiled/lib # MyLibCompiled/bin on Windows
julia/
libinc.dylib
libjulia.1.6.dylib
libjulia.1.dylib
libjulia.dylib
...
```

(These will have a `.so` extension on Linux, and a `.dll` extension on Windows. There may also
be other files in the same directory, depending on your operating system and version of Julia.)

In addition to most of the same keyword arguments as 
[`create_app`](@ref), `create_library` has additional keyword arguments related to library
naming, versioning, and including C header files in the output library bundle. See the function
documentation for details.

Presumably, you're creating the library to use some functionality that is available in Julia
but not (easily) implementable in some other language, like C or C++. To use this functionality
from, e.g., C, you'll need to link against the library, and also make it accessible at run time
(because it's a dynamic library, not a static one).

Here you have different options depending on your operating system and needs.

1. Install the libraries in a non-standard location, and update an appropriate environment
   variable to point to the library location.
   * On Linux and other Unix-like OSes, run `export LD_LIBRARY_PATH=/path/to/lib:$LD_LIBRARY_PATH`
   * On Mac, run `export DYLD_FALLBACK_LIBRARY_PATH=/path/to/lib:$DYLD_FALLBACK_LIBRARY_PATH`
   * On Windows, include the library location in `PATH`. (* NOTE: not tested--does this work? *)

2. (Linux/Unix/Mac) Install the library files in a standard library location. `/usr/local/`
   is one possible location:
   * Libraries would be installed in `/usr/local/lib`
   * Include files would be installed in `/usr/local/include`
   * Julia artifacts and any other depot components would be installed under `/usr/local/share/julia`.
   Note that on Linux, installing under `/usr/local/lib` or another standard location requires 
   that you run `ldconfig` as root after install.

3. (Mac) Include the full library bundle in an application bundle and set the `rpath`
   on the application bundle to the relative path of the library from the executable.

4. (Windows) Include all libraries in the same directory as an executable.

In all cases, you also need to link to the library while building your executable. For C/C++
compilers, the link step looks something like this:

```
cc -o my_application my_application.o -L/path/to/my_library -lmylib
```

Note that on Unix-like operating systems (including Mac), your library must have a `lib` prefix
(e.g., `libmylib.so` (linux/unix) or `libmylib.dylib` (Mac)). `create_library()` ensures this.
(On windows, the `lib` prefix is optional.)

See [here](https://github.com/simonbyrne/libcg) for a more complete example of how this might look.

