module mystuff

using Gadfly
using Distributions
f() = rand(Normal())

Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    println("hello, world")
    @show f()
    plot(x=1:10, y=1:10)
    return 0
end

end

#using mystuff
#mystuff.julia_main()
