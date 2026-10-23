# This could be factored out into its own package sometime,
# there is some overlap with ProgressMeter.jl though.
# Don't depend on PackageCompiler.jl to use this :P
module TerminalSpinners

using Printf

export Spinner, @spin

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
    heartbeat_interval::Float64 = 300.0 # [s], between plain lines when the spinner is disabled
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
    clear_on_finish::Bool=false # on success, leave no final line, and in a terminal erase the spinner output
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

function elapsed_string(s::Spinner)
    # Round before splitting, so 59.6 s carries into the minutes instead of printing as 60 s
    elapsed = round(Int, time() - s.start)
    (minutes, seconds) = fldmod(elapsed, 60)
    (hours, minutes) = fldmod(minutes, 60)

    if hours == 0
        return @sprintf("%02dm:%02ds", minutes, seconds)
    else
        return @sprintf("%02dh:%02dm:%02ds", hours, minutes, seconds)
    end
end

function getline(s::Spinner, spinner, color)
    ioc = IOContext(s.stream, :displaysize=>displaysize(s.stream)) # https://github.com/JuliaLang/julia/issues/42649
    return sprint(; context=ioc) do io
        s.first || erase_and_reset(io, s.nlines)
        printstyled(io, spinner; color, bold=true)
        printstyled(io, " [", elapsed_string(s), "]"; color, bold=true)

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

# Logs that can't redraw a line, such as CI logs, get a plain line per status instead
function render_plain(s::Spinner, status=nothing)
    suffix = status === nothing ? "" : " ($status)"
    println(s.stream, "- ", tostring(s.msg), suffix)
end

function start_timer!(f, s::Spinner, delay, interval)
    s.timer = Timer(delay; interval) do timer
        try
            f()
        catch e
            @error "internal error in spinner" exception=(e, catch_backtrace())
            stop!(s)
        end
    end
end

function start!(s::Spinner)
    s.silent && return
    s.frame_idx = 1
    s.first = true
    s.start = time()

    if !s.enabled
        render_plain(s)
        start_timer!(s, s.heartbeat_interval, s.heartbeat_interval) do
            render_plain(s, "still running, $(elapsed_string(s)) elapsed")
        end
        return
    end

    s.hidecursor && hide_cursor!(s.stream)

    start_timer!(s, 0.0, 1/s.freq) do
        render(s)
        s.first = false
        advance_frame!(s)
    end
    return s
end

function close_timer!(s::Spinner)
    if s.timer !== nothing
        close(s.timer)
        s.timer = nothing
    end
end

function stop!(s::Spinner)
    close_timer!(s)
    if !s.enabled || s.silent
        return
    end
    s.hidecursor && show_cursor!(s.stream)
    println(s.stream)
end

# Erase the spinner's current output, returning the cursor to where it began.
function clear!(s::Spinner)
    s.first || erase_and_reset(s.stream, s.nlines)
    s.hidecursor && show_cursor!(s.stream)
end

function finish!(s, glyph, color, status; clear=false)
    # Stop the timer before the final render so a pending tick can't
    # overwrite the result line with a spinner frame.
    close_timer!(s)
    if s.enabled && !s.silent
        clear && return clear!(s)
        render(s, glyph, color)
    elseif !s.silent && !clear
        render_plain(s, "$status $(elapsed_string(s))")
    end
    stop!(s)
end
success!(s) = finish!(s, "✔", :light_green, "done in"; clear=s.clear_on_finish)
fail!(s) = finish!(s, "✖", :light_red, "failed after")

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
