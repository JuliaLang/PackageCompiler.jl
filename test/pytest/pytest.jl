using PackageCompiler

PackageCompiler.julia_compile(
    joinpath(@__DIR__, "pyshared.jl");
    julia_program_basename = "pyshared",
    verbose = true, quiet = false, object = true,
    sysimage = nothing, cprog = nothing, builddir = @__DIR__,
    cpu_target = nothing, optimize = nothing, debug = nothing,
    inline = nothing, check_bounds = nothing, math_mode = nothing,
    executable = false, shared = true, julialibs = true
)

using PackageCompiler
dir(folders...) = abspath(joinpath(homedir(), "UnicodeFun", folders...))
tmp_dir = dir("build")
o_file = dir("build", "pymodule.o")
cd(dir()) do
    PackageCompiler.build_object(
        dir("pyshared.jl"), escape_string(tmp_dir), dir("build", "juliamodule.o"), true,
        nothing, nothing, nothing, nothing, nothing, nothing, nothing,
        nothing, nothing
    )
end
import PackageCompiler: system_compiler, bitness_flag, julia_flags
cc = "gcc"#system_compiler()
bitness = bitness_flag()
flags = julia_flags()
command = `$cc -shared -fPIC -c $(dir("pymodule.c")) -o $(dir("build", "pymodule.o")) `
command = `$command -IC:\\Python27\\include -IC:\\Python27\\PC`
RPMbindir = PackageCompiler.mingw_dir("bin")
incdir = PackageCompiler.mingw_dir("include")
push!(Base.Libdl.DL_LOAD_PATH, RPMbindir) # TODO does this need to be reversed?
ENV["PATH"] = ENV["PATH"] * ";" * RPMbindir
command = `$command -I$incdir`
try
    run(command)
catch e
    Base.showerror(STDOUT, e)
end

command = `$cc $(bitness_flag()) -mdll -O -Wall -IC:\\Python27\\include -IC:\\Python27\\PC -c $(dir("pymodule.c")) -o build\\pymodule.o`
command = `$command -I$incdir`
run(command)
show(dir("build", "juliamodule.o"))
gcc = PackageCompiler.system_compiler()
command = `$gcc $(bitness_flag()) -shared -fPIC -o pymodule.pyd $(dir("build", "pymodule.o")) $(dir("build", "juliamodule.o"))`
command = `$command -IC:\\Python27\\include -IC:\\Python27\\PC`
flags = julia_flags()
incdir = PackageCompiler.mingw_dir("include")
show(incdir)
command = `$command -I$incdir $flags -D MS_WIN64`
run(command)
cd(@__DIR__)
println(incdir)
run(`$gcc -c pymodule.c -IC:\\Python27\\include -I$incdir`)

gcc -shared hellomodule.o -LC:\Python27\libs -lpython27 -o hello.dll
```



The problem here is that you said that somewhere you will provide the definition of a class called Rectangle -- where the example code states

cdef extern from "Rectangle.h" namespace "shapes":
    cdef cppclass Rectangle:
        ...

However, when you compiled the library you didn't provide the code for Rectangle, or a library that contained it, so rect.so has no idea where to find this Rectangle class.

To run your code you must first create the Rectangle object file.

gcc -c Rectangle.cpp # creates a file called Rectangle.o

Now you can either create a library to dynamically link against, or statically link the object file into rect.so. I'll cover statically linking first as it's simplest.

gcc -shared -fPIC -I /usr/include/python2.7 rect.cpp Rectangle.o -o rect.so

Note that I haven't included the library for python. This is because you expect your library to be loaded by the python interpreter, thus the python libraries will already be loaded by the process when your library is loaded. In addition to providing rect.cpp as a source I also provide Rectangle.o. So lets try running a program using your module.

run.py

import rect
print(rect.PyRectangle(0, 0, 1, 2).getLength())

Unfortunately, this produces another error:

ImportError: /home/user/rectangle/rect.so undefined symbol: _ZTINSt8ios_base7failureE

This is because cython needs the c++ standard library, but python hasn't loaded it. You can fix this by adding the c++ standard library to the required libraries for rect.so

gcc -shared -fPIC -I/usr/include/python2.7 rect.cpp Rectangle.o -lstdc++ \
     -o rect.so

Run run.py again and all should work. However, the code for rect.so is larger than it needs to be, especially if you produce multiple libraries that depend on the same code. You can dynamically link the Rectangle code, by making it a library as well.

gcc -shared -fPIC Rectangle.o -o libRectangle.so
gcc -shared -fPIC -I/usr/include/python2.7 -L. rect.cpp -lRectangle -lstdc++ \
     -o rect.so

We compile the Rectangle
11
down vote


This worked for me with Python 3.3 :

   create static python lib from dll

   python dll is usually in C:/Windows/System32; in msys shell:

   gendef.exe python33.dll

   dlltool.exe --dllname python33.dll --def python33.def --output-lib libpython33.a

   mv libpython33.a C:/Python33/libs

   use swig to generate wrappers

   e.g., swig -c++ -python myExtension.i

   wrapper MUST be compiled with MS_WIN64, or your computer will crash when you import the class in Python

   g++ -c myExtension.cpp -I/other/includes

   g++ -DMS_WIN64 -c myExtension_wrap.cxx -IC:/Python33/include

   shared library

   g++ -shared -o _myExtension.pyd myExtension.o myExtension_wrap.o -lPython33 -lOtherSharedLibs -LC:/Python33/libs -LC:/path/to/other/shared/libs
```
