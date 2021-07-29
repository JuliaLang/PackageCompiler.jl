module MyLib

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

end
