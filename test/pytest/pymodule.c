#include <Python.h>

static PyObject* say_hello(PyObject* self, PyObject* args)
{
    const char* name;

    if (!PyArg_ParseTuple(args, "s", &name))
        return NULL;

    printf("Hello %s!\n", name);

    Py_RETURN_NONE;
}

static PyMethodDef helloworld_funcs[] = {
   {"say_hello", (PyCFunction)say_hello, METH_VARARGS, "say_hello( ): Any message you want to put here!!\n"},
   {NULL}
};

void inithello(void) {
   Py_InitModule3("hello", helloworld_funcs, "nice stuf");
}
