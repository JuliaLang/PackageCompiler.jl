# PackageCompiler

PackageCompiler is a Julia package with two main purposes:

1. Creating custom sysimages for reduced latency when working locally with
   packages that has a high startup time.

2. Creating "apps" which are a bundle of files including an executable that can
   be sent and run on other machines without Julia being installed on that machine.

The manual contains some uses of Linux commands like `ls` (`dir` in Windows)
and `cat` but hopefully these commands are common enough that the points still
come across.

## Installation instructions

!!! note

    It is strongly recommended to use the official binaries that are downloaded from 
    https://julialang.org/downloads/. Distribution-provided Julia installations are
    unlikely to work properly with this package.
  
To use PackageCompiler a C-compiler needs to be available:

### macOS, Linux

Having a decently modern `gcc` or `clang` available should be enough to use PackageCompiler on Linux or macOS.
For macOS, using something like `homebrew` and for Linux the system package manager should work fine.

### Windows

A suitable compiler will be automatically installed the first time it is neeed.
