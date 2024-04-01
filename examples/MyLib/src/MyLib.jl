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

Base.@ccallable function instantiate_FMU(
    name::Cstring,
    type::Cint,
    guid::Cstring,
    location::Cstring,
    callbacks::Ptr{Cvoid},
    visible::Cint,
    loggingOn::Cint)::Ptr{Cvoid}

    p = Ptr{Cvoid}(0x0123456789ABCDEF)
    # println("\nreturning: ", p) # If uncommented, it works?
    return p
end

Base.@ccallable function increment64(count::Clong)::Clong
    count = increment(count)
    println("Incremented count: $count (Clong)")
    return count
end

end
