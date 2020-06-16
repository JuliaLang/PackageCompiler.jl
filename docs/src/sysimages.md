# [Sysimages](@id sysimages)

## What is a sysimage

A sysimage is a file which, in a loose sense, contains a Julia session
serialized to a file.  A "Julia session" includes things like loaded packages,
global variables, inferred and compiled code, etc.  By starting Julia with a
sysimage, the stored Julia session is deserialized and loaded. The idea behind
the sysimage is that this deserialization is faster than having to reload
packages and recompile code from scratch.

Julia ships with a sysimage that is used by default when Julia is started. That
sysimage contains the Julia compiler itself, the standard libraries and also
compiled code that has been put there to reduce the time required to do common
operations, like working in the REPL.

Sometimes it is desirable to create a custom sysimage with custom precompiled
code. This is the case if one has some dependencies that take a significant
time to load or where the compilation time for the first call is uncomfortably
long. This section of the documentation is intended to document how to use
PackageCompiler to create such sysimages.

### Drawbacks to custom sysimages

It should be clearly stated that there are some drawbacks to using a custom
sysimage, thereby sidestepping the standard Julia package precompilation
system.  The biggest drawback is that packages that are compiled into a
sysimage (including their dependencies!) are "locked" to the version they where
at when the sysimage was created. This means that no matter what package
version you have installed in your current project, the one in the sysimage
will take precedence. This can lead to bugs where you start with a project that
needs a specific version of a package, but you have another one compiled into
the sysimage.

Putting packages in the sysimage is therefore only recommended if the load time
of those packages is a significant problem and when these packages
are not frequently updated. In addition, compiling "workflow packages" like
Revise.jl and OhMyREPL.jl and using that as a default sysimage might make sense.

## Creating a sysimage using PackageCompiler

PackageCompiler provides the function [`create_sysimage`](@ref) to create a
sysimage.  It takes as the first argument a package or a list of packages that
should be embedded in the resulting sysimage. By default, the given packages are
loaded from the active project but a specific project can be specified by
giving a path with the `project` keyword. The location of the resulting
sysimage is given by the `sysimage_path` keyword.  After the sysimage is
created, giving the command flag `-Jpath/to/sysimage` will start Julia with the
given sysimage.

Below is an example of a new sysimage, from a separate project, being created
with the package Example.jl in it. Using `Base.loaded_modules` it can be seen
that the package is loaded without having to explicitly `import` it.

```
~
❯mkdir NewSysImageEnv

~
❯ cd NewSysImageEnv

~/NewSysImageEnv 29s
❯ julia -q

julia> using PackageCompiler
[ Info: Precompiling PackageCompiler [dffaa6cc-da53-48e5-b007-4292dfcc27f1]

(v1.3) pkg> activate .
Activating new environment at `~/NewSysImageEnv/Project.toml`

(NewSysImageEnv) pkg> add Example
  Updating registry at `~/.julia/registries/General`
  Updating git-repo `https://github.com/JuliaRegistries/General.git`
 Resolving package versions...
  Updating `~/NewSysImageEnv/Project.toml`
  [7876af07] + Example v0.5.3
  Updating `~/NewSysImageEnv/Manifest.toml`
  [7876af07] + Example v0.5.3

julia> create_sysimage(:Example; sysimage_path="ExampleSysimage.so")
[ Info: PackageCompiler: creating system image object file, this might take a while...

julia> exit()

~/NewSysImageEnv
❯ ls
ExampleSysimage.so  Manifest.toml  Project.toml

~/NewSysImageEnv
❯ julia -q -JExampleSysimage.so

julia> Base.loaded_modules
Dict{Base.PkgId,Module} with 34 entries:
...
  Example [7876af07-990d-54b4-ab0e-23690620f79a]          => Example
...
```

Alternatively, instead of giving a path to where the new sysimage should appear, one
can choose to replace the default sysimage.
This is done by omitting the `sysimage_path` keyword and instead adding `replace_default=true`, for example:

```julia
create_sysimage([:Debugger, :OhMyREPL]; replace_default=true)
```

If this is the first time `create_sysimage` is called with `replace_default`, a
backup of the default sysimage is created. The default sysimage can then be
restored with [`restore_default_sysimage()`](@ref).

Note that sysimages are created "incrementally" in the sense that they add to
the sysimage of the process running PackageCompiler. If the default sysimage
has been replaced, the next `create_sysimage` call will create a new sysimage
based on the replaced sysimage. It is possible to create a sysimage
non-incrementally by passing the `incremental=false` keyword. This will create
a new system image from scratch. However, it will lose the special
precompilation that the Julia bundled sysimage provides which is what make the
REPL and package manager not require compilation after a Julia restart.. It is
therefore unlikely that `incremental=false` is of much use unless in special
cases for sysimage creation (for apps it is a different story though).

### [Compilation of functions](@id tracing)

The step where we included Example.jl in the sysimage meant that loading
Example is now pretty much instant (the package is already loaded when Julia
starts). However, functions inside Example.jl still need to be compiled when
executed for the first time.  One way we can see this is by using the
`--trace-compile=stderr` flag which outputs a "precompile statement" every
time Julia compiles a function.  Running the `hello` function inside Example.jl
we can see that it needs to be compiled (it shows the function
`Example.hello` was compiled for the input type `String`.

```
~/NewSysImageEnv
❯ julia -JExampleSysimage.so --trace-compile=stderr -e 'import Example; Example.hello("friend")'
precompile(Tuple{typeof(Example.hello), String})
```

To remedy this, we can give a "precompile script" to `create_sysimage` which
causes functions executed in that script to be baked into the sysimage. As an
example, the script below simply calls the `hello` function in `Example`:

```
~/NewSysImageEnv
❯ cat precompile_example.jl
using Example
Example.hello("friend")
```

We now create a new system image called `ExampleSysimagePrecompile.so`, where
the `precompile_execution_file` keyword argument has been given, pointing to
the file just shown above:

```julia-repl
~/NewSysImageEnv
❯ julia -q

julia> using PackageCompiler

(v1.3) pkg> activate .
Activating environment at `~/NewSysImageEnv/Project.toml`

julia> PackageCompiler.create_sysimage(:Example; sysimage_path="ExampleSysimagePrecompile.so",
                                         precompile_execution_file="precompile_example.jl")
[ Info: PackageCompiler: creating system image object file, this might take a while...

julia> exit()
```

Using the just created system image, we can see that the `hello` function no longer needs to get compiled:

```
~/NewSysImageEnv
❯ julia -JExampleSysimagePrecompile.so --trace-compile=stderr -e 'import Example; Example.hello("friend")'

~/NewSysImageEnv
❯
```

#### Using a manually generated list of precompile statements

Starting Julia with `--trace-compile=file.jl` will emit precompilation
statements to `file.jl` for the duration of the started Julia process.  This
can be useful in cases where it is difficult to give a script that executes the
code (like with interactive use). A file with a list of such precompile
statements can be used when creating a sysimage by passing the keyword argument
`precompile_statements_file`. See the [OhMyREPL.jl example](@ref manual-omr) in the docs for more
details on how to use `--trace-compile` with PackageCompiler.

It is also possible to use
[SnoopCompile.jl](https://timholy.github.io/SnoopCompile.jl/stable/snoopi/#auto-1)
to create files with precompilation statements.


#### Using a package's test suite to generate precompile statements

It is also possible to use a package's test suite to generate a list of
precompile statements by including the content:

```julia
import Example
include(joinpath(pkgdir(Example), "test", "runtests.jl"))
```

in the precompile file. Note that you need to have any test dependencies installed
in your current project.
