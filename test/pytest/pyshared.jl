using PyCall

Base.@ccallable function helloworld(self::PyObject)::PyObject
    println(self)
    return PyObject("test")
end