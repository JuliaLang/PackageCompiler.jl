Base.@ccallable function julia_hello(user::Ptr{UInt8}, ans::Int)
  println("hello $(bytestring(user)). the answer is $ans")
  return ans
end
