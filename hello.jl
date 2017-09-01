module mystuff

using Gadfly
using Distributions
f() = rand(Normal())

Base.@ccallable Float64 function julia_main()
   println("hello, world")
   @show f()
end

end

#using mystuff
#mystuff.julia_main()
