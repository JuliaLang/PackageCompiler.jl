module Hello

using UnicodePlots

Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    println("hello, world")
    @show sin(0.0)
    println(lineplot(1:100, sin.(linspace(0, 2π, 100))))
    return 0
end

end
