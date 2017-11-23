using PackageCompiler
using Base.Test

# write your own tests here
# If this works without error we should be in pretty good shape!
PackageCompiler.compile_package("Matcha", false)
# TODO test revert - I suppose i wouldn't have enough rights on travis to move around dll's?
