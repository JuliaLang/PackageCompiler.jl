#using PyCall

Base.@ccallable function julia_test()::Void
    println("Jo mah man!!!")
    return #PyObject("test")
end