#include <Python.h>
#include "julia.h"

extern void julia_test(void);

static PyObject* say_hello(PyObject* self, PyObject* args)
{
    const char* name;

    if (!PyArg_ParseTuple(args, "s", &name))
        return NULL;

    printf("Hello %s!\n", name);
    julia_test();
    Py_RETURN_NONE;
}

static PyMethodDef helloworld_funcs[] = {
   {"say_hello", (PyCFunction)say_hello, METH_VARARGS, "say_hello( ): Any message you want to put here!!\n"},
   {NULL}
};

void inithello(void) {
    libsupport_init();
    // jl_options.compile_enabled = JL_OPTIONS_COMPILE_OFF;
    // JULIAC_PROGRAM_LIBNAME defined on command-line for compilation
    jl_options.image_file = "/home/s/.julia/v0.6/PackageCompiler/test/pytest/pyshared";
    julia_init(JL_IMAGE_JULIA_HOME);

    Py_InitModule3("hello", helloworld_funcs, "nice stuf");
}
