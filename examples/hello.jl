module Hello

using UnicodePlots

Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    println("hello, world")
    @show sin(0.0)
    println(lineplot(1:10, sin.(linspace(0, 4, 10))))
    return 0
end

end
