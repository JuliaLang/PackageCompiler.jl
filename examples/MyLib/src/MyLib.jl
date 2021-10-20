module MyLib

using Artifacts

export increment32, increment64

function increment(count)
    count += 1
    return count
end

Base.@ccallable function increment32(count::Cint)::Cint
    count = increment(count)
    println("Incremented count: $count (Cint)")
    return count
end

Base.@ccallable function increment64(count::Clong)::Clong
    count = increment(count)
    println("Incremented count: $count (Clong)")
    return count
end

fooifier_path() = joinpath(artifact"fooifier", "bin", "fooifier" * (Sys.iswindows() ? ".exe" : ""))

Base.@ccallable function run_artifact()::Cvoid
    res = read(`$(fooifier_path()) 5 10`, String)
    println("The result of 2*5^2 - 10 == $res")
    return nothing
end

end
