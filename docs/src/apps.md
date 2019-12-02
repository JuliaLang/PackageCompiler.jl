# Apps

## Relocatability


### Artifacts

PackageCompilerX provdes a function `audit_app(project::String)[@ref]` that tries to find common problems

## Incremental vs non-incremental sysimage

Creating a sysimage can in PackageCompilerX either be done "from scratch" (`incremental=false`) or it can
be done as a 


### Incremental vs non-incremental sysimages

By default, when creating a sysimage with PackageCompilerX, the sysimage is created in "incremental"-mode.
This means that the 
This has the benefit that 


## Standard library filtering

As an example, 


## What things are being leaked

### Absolute paths of build machine

### Lowered code

### Name and fieldname of types
