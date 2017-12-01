using PackageCompiler
using Base.Test

# If this works without error we should be in pretty good shape!
# This command will use the runtest.jl of Matcha to find out what functions to precompile!
PackageCompiler.compile_package("Matcha", false) # false to not force overwriting julia's current system image
# TODO test revert - I suppose i wouldn't have enough rights on travis to move around dll's?
