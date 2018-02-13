module Hello

using UnicodePlots
using Distributions
f() = rand(Normal())

Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    println("hello, world")
    @show f()
    println(lineplot(1:10, (1:10).^2))
    return 0
end

end
