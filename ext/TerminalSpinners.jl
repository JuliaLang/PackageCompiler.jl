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

function count_lines_without_ansi(width::Int, str::String)
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
    frames::Vector{String} =  ["⠋", "⠙", "⠸", "⢰", "⣠", "⣄", "⡆", "⠇"]
    freq::Float64 = 10.0 # [1/s]
    msg::Any = ""
    stream::IO_t = stderr   
    timer::Union{Nothing, Timer} = nothing
    hidecursor::Bool = true
    silent::Bool=false
    enabled::Bool= silent ? false : stream isa Base.TTY && !haskey(ENV, "CI")
    frame_idx::Int=1
    start = time()
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
        printstyled(io, spinner; color, bold=true)

        elapsed = time() - s.start
        (minutes, seconds) = fldmod(elapsed, 60)
        (hours, minutes) = fldmod(minutes, 60)

        if hours == 0
            printstyled(io, @sprintf(" [%02dm:%02ds]", minutes, seconds); color, bold=true)
        else
            printstyled(io, @sprintf(" [%02dh:%02dm:%02ds]", hours, minutes, seconds); color, bold=true)
        end

        msg = tostring(s.msg)
        print(io, " ", msg)
    end
end

function render(s::Spinner, spinner=getframe(s), color=s.color)
    s.silent && return
    str = getline(s, spinner, color)
    s.nlines = count_lines_without_ansi(displaysize(s.stream)[2], str)
    print(s.stream, str)
    return
end

function start!(s::Spinner)
    s.silent && return
    s.frame_idx = 1
    s.first = true
    s.start = time()
    
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
            @error "internal error in spinner" exception=(e, catch_backtrace())
            stop!(s)
        end
    end
    s.timer = t
    return s
end

function stop!(s::Spinner)
    if s.timer !== nothing
        close(s.timer)
    end
    if !s.enabled || s.silent 
        return
    end
    s.hidecursor && show_cursor!(s.stream)
    println(s.stream)
end

function success!(s)
    if s.enabled && !s.silent
        render(s, "✔", :light_green)
    end
    stop!(s)
end
function fail!(s)
    if s.enabled && !s.silent
        render(s, "✖", :light_red)
    end
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