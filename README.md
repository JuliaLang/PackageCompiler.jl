# PackageCompiler

[![Build Status](https://travis-ci.org/SimonDanisch/PackageCompiler.jl.svg?branch=master)](https://travis-ci.org/SimonDanisch/PackageCompiler.jl)

[![Coverage Status](https://coveralls.io/repos/SimonDanisch/PackageCompiler.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/SimonDanisch/PackageCompiler.jl?branch=master)

[![codecov.io](http://codecov.io/github/SimonDanisch/PackageCompiler.jl/coverage.svg?branch=master)](http://codecov.io/github/SimonDanisch/PackageCompiler.jl?branch=master)

Remove jit overhead from your package and compile it into a system image.

## Usage Example
E.g. do:
```Julia
using PackageCompiler

# This command will use the runtest.jl of Matcha + UnicodeFun to find out what functions to precompile!
# force = false to not force overwriting julia's current system image
PackageCompiler.compile_package("Matcha", "UnicodeFun", force = false, reuse = false) 

# build again, with resuing the snoop file
PackageCompiler.compile_package("Matcha", "UnicodeFun", force = false, reuse = true)

# You can define a file that will get run for snooping explicitely like this:
# this makes sure, that binary gets cached for all functions called in `for_snooping.jl`
PackageCompiler.compie_package(("Matcha", "relative/path/for_snooping.jl"))

# if you used force and want your old system image back (force will overwrite the default system image Julia uses) you can run:
PackageCompiler.revert() 
```


## Trouble shooting:

- You might need to tweak your runtest, since SnoopCompile can have problems with some statements. Please open issues about concrete problems! This is also why there is a way to point to a file different from runtests.jl, for the case it becomes impossible to combine testing and snoop compiling (just pass `("package", "snoopfile.jl")`)!

- non const globals are problematic, or globals defined in functions - removing those got me to 95% of making the package safe for static compilation

- type unstable code had some inference issues (around 2 occurrence, where I’m still not sure what was happening) - both cases happened with dictionaries… Only way to find those was investigating the segfaults with `gdb`, but then it was relatively easy to just juggle around the code, since the stacktraces accurately pointed to the problem. The non const globals might be related since they introduce type instabilities.

- some generated functions needed reordering of the functions they call ( actually, even for normal compilation, all functions that get called in a generated function should be defined before it)

- I uncovered one out of bounds issue, that somehow was not coming up without static-compilation
- I used julia-debug to uncover most bugs, but actually, the last errors I was trying to uncover where due to using julia-debug!

- you’re pretty much on your own and need to use gdb to find the issues and I still don’t know what the underlying julia issues are and when they will get fixed :wink: See: https://github.com/JuliaLang/julia/issues/24533. Hopefully we look at a better story with Julia 1.0!
