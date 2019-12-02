# PackageCompilerX

PackageCompilerX is a Julia package with two main purposes:

1. Creating custom sysimages for reduced latency when working locally with
   packages that has a high startup time.

2. Creating "apps" which are a bundle of files including an executable that can
   be sent and run on other machines without Julia being installed on that machine.

The manual contains some uses of Linux commands like `ls` (`dir` in Windows)
and `cat` but hopefully these commands are common enough that the points still
come across).


## Manual Outline

```@contents
Pages = [
    "prereq.md",
    "sysimages.md",
    "apps.md",
    "examples/ohmyrepl.md",
]
Depth = 1
```

