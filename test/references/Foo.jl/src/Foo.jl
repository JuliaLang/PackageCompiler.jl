module Foo

using Random

const init_counter = Ref{Int}(0)
function __init__()
    init_counter += 1
    @info "Foo.__init__() called"
    if init_counter > 1
        error("Foo.__init__() was called more than once")
    end
end

function bar(x)
    init_counter > 0 || error("Foo.bar called before Foo's __init__() was called")
    randstring(x)
end

end # module