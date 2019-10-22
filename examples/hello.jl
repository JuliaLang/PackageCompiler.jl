Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    println("hello, world")
    @show sin(0.0)
    return 0
end

