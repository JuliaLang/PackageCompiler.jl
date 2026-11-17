# Julia distributions

`create_distribution` builds a relocatable Julia installation with the packages from a
project embedded in its sysimage. The packages are also registered as stdlibs, so they can
be loaded without activating or shipping the original project.

For a project containing `Project.toml` (and preferably a pinned `Manifest.toml`), run:

```julia
using PackageCompiler

create_distribution("MyProject", "MyJulia")
```

The resulting Julia executable is `MyJulia/bin/julia` (`julia.exe` on Windows). The bundle
targets the same operating system and architecture as the Julia process that created it.

Package source is replaced by small placeholders because its implementation is already in
the sysimage. If packages need data or source files at runtime, select them with
`copy_globs`. Patterns are evaluated relative to every package root:

```julia
create_distribution("MyProject", "MyJulia";
                    copy_globs=["assets/**", "ext/**", r"LICENSE.*"])
```

See [`create_distribution`](@ref) for compilation, artifact, and compression options.
