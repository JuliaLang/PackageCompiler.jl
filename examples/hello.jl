module Hello

using UnicodePlots

Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    println("hello, world")
    @show sin(0.0)
    println(lineplot(1:100, sin.(range(0, stop=2π, length=100))))
    return 0
end

end
