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
