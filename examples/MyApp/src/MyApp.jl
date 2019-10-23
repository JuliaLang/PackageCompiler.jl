module MyApp

using Example

greet() = print("Hello World!")

Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    println("hello, world")
    @show Example.domath(5)
    @show sin(0.0)
    return 0
end

end # module
