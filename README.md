# PackageCompiler

[![Build Status](https://travis-ci.org/JuliaLang/PackageCompiler.jl.svg?branch=master)](https://travis-ci.org/JuliaLang/PackageCompiler.jl)
[![Codecov](https://codecov.io/gh/JuliaLang/PackageCompiler.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaLang/PackageCompiler.jl)
[![][docs-stable-img]][docs-stable-url]

PackageCompiler is a Julia package with two main purposes:

  1. Creating custom sysimages for reduced latency when working locally with packages that has a high startup time.

  2. Creating "apps" which are a bundle of files including an executable that can be sent and run on other machines without Julia being installed on that machine.

For installation and usage instructions, see the [documentation][docs-stable-url].

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://JuliaLang.github.io/PackageCompiler.jl/dev
