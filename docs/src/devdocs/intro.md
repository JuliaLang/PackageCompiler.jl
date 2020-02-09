# Introduction

This part of the documentation contains a set of tutorials aimed to teach how
PackageCompiler works internally. This is done by going through some examples
of manually creating sysimages and apps, mostly from the command line.
By knowing the internals of PackageCompiler you can more easily figure out
root causes of problems and help others. The inner functionality of PackageCompiler
is actually quite simple. There are a few julia commands and compiler invocations
that everything is built around, the rest is mostly scaffolding.

[Part 1](@ref man-tutorial-sysimage) focuses on how to build a local system
image to reduce package load times and reduce the latency that can occur when
calling a function for the first time. [Part 2](@ref man-tutorial-binary)
targets how to build an executable based on the custom sysimage so that it can
be run without having to explicitly start a Julia session. [Part 3](@ref man-tutorial-reloc)
details how to bundle that executable together with the Julia libraries and
other files needed so that the bundle can be sent to and run on a different
system where Julia might not be installed. These functionalities are exposed
from PackageCompiler as [`create_sysimage`](@ref) and [`create_app`](@ref).

It should be noted that there is some usage of non-documented Julia functions
and flags.  They have not been changed for quite a long time (and are unlikely
to change too much in the future), but some care should be taken.

