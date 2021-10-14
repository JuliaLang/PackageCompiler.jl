# This could be factored out into its own package sometime,
# there is some overlap with ProgressMeter.jl though.
# Don't depend on PackageCompiler.jl to use this :P
module TerminalSpinners

using Printf

export Spinner, autospin, spin!, @spin

const CSI = "\e["

show_cursor!(io::IO) = print(io, CSI, "?25h")
hide_cursor!(io::IO) = print(io, CSI, "?25l")
cursor_up!(io::IO, n=1) = print(io, CSI, n, 'A')
cursor_down!(io::IO, n=1) = print(io, CSI, n, 'B')
cursor_horizontal_absolute!(io::IO, n=1) = print(io, CSI, n, 'G')

@enum EraseLineMode begin
    CURSOR_TO_END = 0
    CURSOR_TO_BEGINNING = 1
    ENTIRE_LINE = 2
end
erase_line!(io::IO, mode::EraseLineMode=ENTIRE_LINE) = print(io, CSI, Int(mode), 'K')

function remove_ansi_characters(str::String)
    r = r"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"
    return replace(str, r => "")
end

function count_lines_no_ansi(io::IO, str::String)
    width = displaysize(io)[2]
    n_lines = 0
    for line in readlines(IOBuffer(remove_ansi_characters(str)))
        w, f = divrem(textwidth(line), width)
        n_lines += w + (f > 0)
    end
    return n_lines
end

tostring(msg) = msg
tostring(f::Function) = f()

Base.@kwdef mutable struct Spinner{IO_t <: IO}
    frames::Vector{String} = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    freq::Float64 = 10.0 # [1/s]
    msg::Any = ""
    stream::IO_t = stderr   
    timer::Union{Nothing, Timer} = nothing
    hidecursor::Bool = true
    silent::Bool=false
    enabled::Bool= silent ? false : stream isa Base.TTY && !haskey(ENV, "CI")
    frame_idx::Int=1
    color::Symbol = Base.info_color()
    nlines::Int=0
    first::Bool=false
end

getframe(s::Spinner) = s.frames[s.frame_idx]

function advance_frame!(s::Spinner)
    frame = s.frames[s.frame_idx]
    s.frame_idx = s.frame_idx == length(s.frames) ? 1 : s.frame_idx + 1
    return frame
end

function erase_and_reset(io::IO, n_lines::Int)
    erase_line!(io)
    for _ in 1:n_lines-1
        cursor_up!(io, 1)
        erase_line!(io)
    end
    cursor_horizontal_absolute!(io, 1)
end

function getline(s::Spinner, spinner, color)
    ioc = IOContext(s.stream, :displaysize=>displaysize(s.stream)) # https://github.com/JuliaLang/julia/issues/42649
    return sprint(; context=ioc) do io
        s.first || erase_and_reset(io, s.nlines)
        printstyled(io, spinner; color)
        msg = tostring(s.msg)
        print(io, " ", msg)
    end
end

function render(s::Spinner, spinner=getframe(s), color=s.color)
    s.silent && return
    str = getline(s, spinner, color)
    s.nlines = count_lines_no_ansi(s.stream, str)
    print(s.stream, str)
    return
end

function start!(s::Spinner)
    s.silent && return
    
    if !s.enabled
        println(s.stream, "- ", s.msg)
        return
    end

    s.hidecursor && hide_cursor!(s.stream)

    t = Timer(0.0; interval=1/s.freq) do timer
        try
            render(s)
            s.first = false
            advance_frame!(s)
        catch e
            close(timer)
            @show "internal error in spinner: $e"
        end
    end
    s.timer = t
    return s
end

function stop!(s::Spinner)
    if s.timer !== nothing
        close(s.timer)
    end
    s.frame_idx = 1
    s.first=true
    if !s.enabled || s.silent 
        return
    end
    s.hidecursor && show_cursor!(s.stream)
    println(s.stream)
end

function success!(s)
    render(s, "✓", :light_green)
    stop!(s)

end
function fail!(s)
    render(s, "✖", :light_red)
    stop!(s)
end

macro spin(s, work)
    return quote
        spin(() -> $(esc(work)), $(esc(s)))
    end
end

function spin(f, s::Spinner)
    start!(s)
    try
        v = f()
        success!(s)
        v
    catch
        fail!(s)
        rethrow()
    end
end


end # module