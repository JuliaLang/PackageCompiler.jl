from setuptools import setup, Extension
import shutil
import os
extension = Extension('hello',
    sources = ['pymodule.c'],
    extra_objects = ['/home/s/.julia/v0.6/PackageCompiler/test/pytest/pyshared.o'],
    extra_link_args = ["-DJULIA_ENABLE_THREADING=0", "-std=gnu99", "-fPIC", "-Wl,--export-dynamic"],
    libraries = ['julia'],
    runtime_library_dirs = ['/home/s/juliastuff/julia6_2/lib', '/home/s/juliastuff/julia6_2/lib/julia', '/home/s/.julia/v0.6/PackageCompiler/test/pytest/'],
    library_dirs = ['/home/s/juliastuff/julia6_2/lib'],
    include_dirs = ['/home/s/juliastuff/julia6_2/include/julia'],
    define_macros = [("JULIA_ENABLE_THREADING", "0")],
    language = 'c'
)

setup(name='hello', version='1.0',  \
    ext_modules=[extension])

