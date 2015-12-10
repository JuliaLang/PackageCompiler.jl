# Declare a function that is callable from C
Base.@ccallable function julia_hello(user::Ptr{UInt8}, ans::Int)
  # parse the arguments and demonstrate that
  # assorted string processing and IO operations are functional
  println("hello $(bytestring(user)). the answer is $ans")
  # and return a value to show that it can,
  # and compute other random and matrix properties
  # as well, so show they are working
  return floor(Int, mean(rand(Int, ans, ans)))
end
