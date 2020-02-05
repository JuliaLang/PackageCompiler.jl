# PackageCompilerX

PackageCompilerX is a Julia package with two main purposes:

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
  
To use PackageCompilerX a C-compiler needs to be available:

### macOS, Linux

Having a decently modern `gcc` or `clang` available should be enough to use PackageCompilerX on Linux or macOS.
For macOS, using something like `homebrew` and for Linux the system package manager should work fine.

### Windows

For Windows, the minGW compiler toolchain is needed. It can be downloaded from e.g.
[https://sourceforge.net/projects/mingw-w64/files/](https://sourceforge.net/projects/mingw-w64/files/) or by following the 
instructions for setting up a toolchain capable of compiling Julia itself on Windows at
[https://github.com/JuliaLang/julia/blob/master/doc/build/windows.md#cygwin-to-mingw-cross-compiling](https://github.com/JuliaLang/julia/blob/master/doc/build/windows.md#cygwin-to-mingw-cross-compiling)
and then run PackageCompilerX from the cygwin terminal. Alternatively, the package manager
[chocolatey](https://chocolatey.org/) can be used to get mingw on Windows.
