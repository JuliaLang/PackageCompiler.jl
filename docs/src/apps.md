# [Apps](@id apps)

With an "app" we here mean a "bundle" of files where one of these files is an
executable and where this bundle can be sent to another machine while still allowing
the executable to run.

Use-cases for Julia-apps are for example when one wants to provide some kind of
functionality where the fact that the code was written in Julia is just an
implementation detail and where requiring the user to download and use Julia to
run the code would be a distraction. There is also no need to provide the
original Julia source code for apps since everything gets baked into the
sysimage.


## Creating an app

The source of an app is a package with a project and manifest file.
You can easily create this using the package manager:

```julia
using Pkg
Pkg.generate("MyApp")
```

In the code for the package, there should be a function with the signature

```julia
function julia_main()::Cint
  # do something based on ARGS?
  return 0 # if things finished successfully
end
```

defined ([you can customize this](@ref multiple)), which will be the entry point of the app (the function that runs when the
executable in the app is run). A skeleton of an app to start working from can
be found [here](https://github.com/JuliaLang/PackageCompiler.jl/tree/master/examples/MyApp).

The app is then compiled using the [`create_app`](@ref) function that takes a
path to the source code of the app and the destination where the app should be
compiled to. This will bundle all required libraries for the app to run on
another machine where the same Julia that created the app can run.  As an
example, in the code snippet below, the example app linked above is compiled and run:

```
~/PackageCompiler.jl/examples
❯ julia -q --project

julia> using PackageCompiler

julia> create_app("MyApp", "MyAppCompiled")
[ Info: PackageCompiler: creating base system image (incremental=false), this might take a while...
[ Info: PackageCompiler: creating system image object file, this might take a while...

julia> exit()

~/PackageCompiler.jl/examples
❯ MyAppCompiled/bin/MyApp foo bar --julia-args -t4
ARGS = ["foo", "bar"]
Base.PROGRAM_FILE = "./bin/MyApp"
DEPOT_PATH = ["/home/kc/JuliaPkgs/PackageCompiler.jl/MyAppCompiled/share/julia"]
...
Running the artifact
The result of 2*5^2 - 10 == 40.000000
```

Note that the arguments passed to the executable are available in the global variable `ARGS`.
Standard julia arguments (like how many threads should be used) are passed in after the
`--julia-args` argument.

The resulting executable is found in the `bin` folder in the compiled app
directory.  The compiled app directory `MyAppCompiled` could now be put into an
archive and sent to another machine or an installer could be wrapped around the
directory, perhaps providing a better user experience than just an archive of
files.

### Compilation of functions

In the same way as [files for precompilation could be given when creating
sysimages](@ref tracing), the same keyword arguments are used to add precompilation to apps.

### Incremental vs non-incremental sysimage

In the section about creating sysimages, there was a short discussion about
incremental vs non-incremental sysimages. In short, an incremental sysimage is
built on top of another sysimage, while a non-incremental is created from
scratch. For sysimages, it makes sense to use an incremental sysimage built on
top of Julia's default sysimage since we wanted the benefit of having a responsive
REPL that it provides.  For apps, this is no longer the case, the sysimage is
not meant to be used when working interactively, it only needs to be
specialized for the specific app.  Therefore, by default, `incremental=false` is
used for `create_app`. If, for some reason, one wants an incremental sysimage,
`incremental=true` could be passed to `create_app`. With the example app, a
non-incremental sysimage is about 70MB smaller than the default sysimage.

### Filtering stdlibs

By default, all standard libraries are included in the sysimage. It is
possible to only include those standard libraries that the project needs.  This
is done by passing the keyword argument `filter_stdlibs=true` to `create_app`.
This causes the sysimage to be smaller, and possibly load faster. The reason
this is not the default is that it is possible to "accidentally" depend on a
standard library without it being reflected in the Project file. For example,
it is possible to call `rand()` from a package without depending on Random,
even though that is where the method is defined. If Random was excluded from
the sysimage that call would then error. As another example, matrix
multiplication, `rand(3,3) * rand(3,3)` requires both the standard libraries
`LinearAlgebra` and `Random` This is because these standard libraries practice
["type-piracy"](https://docs.julialang.org/en/v1/manual/style-guide/#Avoid-type-piracy), 
just loading those packages can cause code to change behavior.

Nevertheless, the option is there to use. Just make sure to properly test the
app with the resulting sysimage.


### [Multiple executables](@id multiple)

By default, the binary in the `bin` directory takes the name of the project, as
defined in `Project.toml` and the julia function that will be called when
running it is `julia_main`. You can change the executable name and the julia
function using the `executables` keyword argument to `create_app`. As an
example, if you want to have two executables called `A` and `B` calling the
julia functions `main_A` and `main_B`, respectively, you would pass
`executables= ["A" => "main_A", "B" => "main_B"]`.  Note that `main_A` and `main_B`
both need to not take any arguments and be annotated to return a `Cint`, for example:

```jl
function main_A()::Cint
    ...
end
```

## [Relocatability](@id relocatability)

Since we want to send the app to other machines the app we create must be
"relocatable".  With an app being relocatable we mean it does not rely on
specifics of the machine where the app was created.  Relocatability is not an
absolute measure, most apps assume some properties of the machine they will run
on, like what operating system is installed and the presence of graphics
drivers if one wants to show graphics. On the other hand, embedding things into
the app that is most likely unique to the machine, such as absolute paths to
libraries, means that the application almost surely will not run properly on
another machine.

For something to be relocatable, everything that it depends on must also be
relocatable.  In the case of an app, the app itself and all the Julia packages
it depends on must also relocatable. This is a bit of an issue because the
Julia package ecosystem has rarely given much thought to relocatability
since creating "apps" has not been common.

The main problem with relocatability of Julia packages is that many packages
are encoding fundamentally non-relocatable information *into the source code*.
As an example, many packages tend to use a `build.jl` file (which runs when the
package is first installed) that looks something like:

```julia
lib_path = find_library("libfoo")
write("deps.jl", "const LIBFOO_PATH = $(repr(lib_path))")
```

The main package file then contains:

```julia
module Package

if !isfile("../build/deps.jl")
    error("run Pkg.build(\"Package\") to re-build Package")
end
include("../build/deps.jl")
function __init__()
    libfoo = Libdl.dlopen(LIBFOO_PATH)
end

...

end # module
```

The absolute path to `lib_path` that `find_library` found is thus effectively
included into the source code of the package. Arguably, the whole build system
in Julia is inherently non-relocatable because it runs when the package is
being installed which is a concept that does not make sense when distributing
an app.

Some packages do need to call into external libraries and use external binaries
so the question then arises: "how are these packages supposed to do this in a
relocatable way?"  The answer is to use the "artifact system" introduced in
Julia 1.3, and described in the following [blog
post](https://julialang.org/blog/2019/11/artifacts). The artifact system is a
declarative way of downloading and using "external files" like binaries and
libraries.  How this is used in practice is described later. Another useful
tool is the Julia package [RelocatableFolders.jl](https://github.com/JuliaPackaging/RelocatableFolders.jl).

### Artifacts

The way to depend on external libraries or binaries when creating apps is by
using the [artifact system](https://julialang.github.io/Pkg.jl/v1/artifacts/).
PackageCompiler will bundle all artifacts needed by the project, and set up
things so that they can be found during runtime on other machines.

The example app uses the artifact system to depend on a very simple toy binary
that does some simple arithmetic. It is instructive to see how the [artifact
file](https://github.com/JuliaLang/PackageCompiler.jl/blob/master/examples/MyApp/Artifacts.toml)
is [used in the source](https://github.com/JuliaLang/PackageCompiler.jl/blob/d722a3d91abe328ebd239e2f45660be35263ebe1/examples/MyApp/src/MyApp.jl#L7-L8).

### Reverse engineering the compiled app

While the created app is relocatable and no source code is bundled with it,
there are still some things about the build machine and the source code that
can be "reverse engineered".

#### Absolute paths of the build machine

Julia records the paths and line-numbers for methods when they are getting
compiled.  These get cached into the sysimage and can be found e.g. by dumping
all strings in the sysimage:

```
~/PackageCompiler.jl/examples/MyAppCompiled/bin
❯ strings MyApp.so | grep MyApp
MyApp
/home/kc/PackageCompiler.jl/examples/MyApp/
MyApp
/home/kc/PackageCompiler.jl/examples/MyApp/src/MyApp.jl
/home/kc/PackageCompiler.jl/examples/MyApp/src
MyApp.jl
/home/kc/PackageCompiler.jl/examples/MyApp/src/MyApp.jl
```

This is a problem that the Julia standard libraries themselves have:

```julia-repl
julia> @which rand()
rand() in Random at /buildworker/worker/package_linux64/build/usr/share/julia/stdlib/1.7/Random/src/Random.jl:256
```

#### Using reflection and finding lowered code

There is nothing preventing someone from starting Julia with the sysimage that
comes with the app. In fact, to support distributed computing that needs to
start up new Julia processes, there is also a `julia` executable in the `bin` folder
that uses the custom sysimage. While the source code is not available one can read
the "lowered code" and use reflection to find things like the name of fields in
structs and global variables etc:

```julia-repl
~/PackageCompiler.jl/examples/MyAppCompiled/bin
❯ ./julia -q

julia> names(MyApp; all=true)
18-element Vector{Symbol}:
 Symbol("#1#3")
 Symbol("#2#4")
 Symbol("#eval")
 Symbol("#fooifier_path")
 Symbol("#include")
 Symbol("#is_crayons_loaded")
 Symbol("#julia_main")
 Symbol("#real_main")
 :MyApp
 :eval
 :fooifier_path
 :include
 :is_crayons_loaded
 :julia_main
 :myrand
 :o
 :outputo
 :real_main

julia> @code_lowered MyApp.real_main()
CodeInfo(
1 ─        Core.NewvarNode(:(#2))
│          Core.NewvarNode(:(n))
│   %3   = MyApp.ARGS
│          value@_17 = %3
│   %5   = Base.repr(%3)
│          Base.println("ARGS = ", %5)
│          value@_17
│   %8   = Base.PROGRAM_FILE
│          value@_16 = %8
│   %10  = Base.repr(%8)
...
```
