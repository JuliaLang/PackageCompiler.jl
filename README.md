# PackageCompiler

[![Continuous integration](https://github.com/JuliaLang/PackageCompiler.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaLang/PackageCompiler.jl/actions/workflows/ci.yml)
[![Codecov](https://codecov.io/gh/JuliaLang/PackageCompiler.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaLang/PackageCompiler.jl)
[![][docs-stable-img]][docs-stable-url]

PackageCompiler is a Julia package with three main purposes:

  1. Creating custom sysimages for reduced latency when working locally with packages that have high startup times.

  2. Creating "apps" which are a bundle of files including an executable that can be sent and run on other machines without Julia being installed on that machine.

  3. Creating a relocatable C library bundle form of Julia code.

For installation and usage instructions, see the [documentation][docs-stable-url].

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://JuliaLang.github.io/PackageCompiler.jl

## Upgrading from PackageCompiler 1.0

PackageCompiler 2.0 comes with a few breaking changes. Read the [upgrade guide](https://julialang.github.io/PackageCompiler.jl/dev/#Upgrading-from-PackageCompiler-1.0.)
for instructions on how to upgrade to version 2.0.
