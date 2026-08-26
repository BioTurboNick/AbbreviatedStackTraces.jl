#= Abbreviation is only active on the REPL's error path — it is driven by the `:compacttrace`
IOContext that `repl_display_error_abbrv` installs — so the user-visible behavior cannot be
tested without a REPL. These helpers drive a real `REPL.run_repl` over a pair of pipes, so a
test observes exactly the text that would appear at a prompt. =#

module FakeTerminals

import REPL

mutable struct FakeTerminal <: REPL.Terminals.UnixTerminal
    in_stream::Base.IO
    out_stream::Base.IO
    err_stream::Base.IO
    hascolor::Bool
    raw::Bool
    FakeTerminal(i, o, e, hascolor = false) = new(i, o, e, hascolor, false)
end

REPL.Terminals.hascolor(t::FakeTerminal) = t.hascolor
REPL.Terminals.raw!(t::FakeTerminal, raw::Bool) = t.raw = raw
REPL.Terminals.size(::FakeTerminal) = (24, 80)

end # module FakeTerminals

using .FakeTerminals: FakeTerminal

# Generous: only reached if a session wedges, in which case the test should fail, not hang
const REPL_TIMEOUT = 300

function repl_options()
    opts = (; confirm_exit = false, hascolor = false)
    # 1.12 added bracket auto-insertion, which would mangle "typed" input
    if :auto_insert_closing_bracket ∈ fieldnames(REPL.Options)
        opts = (; opts..., auto_insert_closing_bracket = false)
    end
    return REPL.Options(; opts...)
end

"""
    repl_output(inputs...) -> String

Evaluate each of `inputs` at a fresh fake REPL prompt and return everything the REPL
printed, with ANSI escapes and prompt echoes removed.
"""
function repl_output(inputs::AbstractString...)
    input, output, err = Pipe(), Pipe(), Pipe()
    for p ∈ (input, output, err)
        Base.link_pipe!(p, reader_supports_async = true, writer_supports_async = true)
    end

    repl = REPL.LineEditREPL(FakeTerminal(input.out, output.in, err.in), false)
    repl.options = repl_options()
    repl.specialdisplay = REPL.REPLDisplay(repl)
    repl.history_file = false

    #= At a real prompt the terminal and `stdout` are the same stream, and code that writes
    to `stdout` directly — `show(err)`, say — is part of what a user sees. =#
    saved_stdout = stdout
    redirect_stdout(output.in)

    repltask = @async REPL.run_repl(repl)
    # Closing the handles is the supported way to tear down a wedged fake REPL
    watchdog = Timer(_ -> (close(input.in); close(output.in)), REPL_TIMEOUT)

    try
        for line ∈ inputs
            write(input.in, line, '\n')
        end
        write(input.in, "\x04") # ^D exits once the queued input has been consumed
        close(input.in)
        wait(repltask)
    finally
        redirect_stdout(saved_stdout)
        close(watchdog)
        close(output.in)
        close(err.in)
    end

    @test read(err.out, String) == ""
    return clean_repl_output(read(output.out, String))
end

const ANSI_ESCAPE = r"\e\[[0-9;?]*[a-zA-Z]|\e\][^\a]*\a|\e."

#= The line editor redraws the prompt on every keystroke, so the raw stream is mostly prompt
echoes. Everything the package prints lands on lines of its own, none of which can contain a
prompt. =#
function clean_repl_output(raw::AbstractString)
    lines = split(replace(raw, ANSI_ESCAPE => ""), r"\r?\n")
    filter!(l -> !contains(l, "julia> "), lines)
    return strip(join(lines, '\n'), ['\n', ' '])
end

"""
    error_block(inputs...) -> String

The text the REPL printed for the error raised by the last of `inputs`, from the `ERROR:`
line onward.
"""
function error_block(inputs::AbstractString...)
    out = repl_output(inputs...)
    i = findlast("ERROR: ", out)
    i === nothing && error("no error was reported; the REPL printed:\n$out")
    return strip(out[first(i):end], ['\n', ' '])
end

"""
    trace_section(text) -> String

The trailing `Stacktrace:` section of a rendered error, so that assertions about a trace are
not accidentally satisfied by the exception message above it.
"""
function trace_section(text::AbstractString)
    i = findlast("\nStacktrace:", text)
    i === nothing && error("no stacktrace was printed in:\n$text")
    return strip(text[first(i):end], ['\n', ' '])
end

"The trailing `Stacktrace:` section of [`error_block`](@ref)."
trace_block(inputs::AbstractString...) = trace_section(error_block(inputs...))

const FRAME = r"^ *\[\d+\] "
const FRAME_NUMBER = r"^ *\[\d+\]"

"""
    lines(block) -> Lines

Split a printed block for indexed assertions. Out-of-range indices give `""` so that an
unexpected line count fails a single assertion instead of erroring out of the testset.
"""
struct Lines
    v::Vector{SubString{String}}
end
lines(block::AbstractString) = Lines(split(block, '\n'))
Base.getindex(l::Lines, i::Int) = checkbounds(Bool, l.v, i) ? l.v[i] : ""
Base.length(l::Lines) = length(l.v)
Base.show(io::IO, l::Lines) = print(io, join(l.v, '\n'))

"""
    aligned(block) -> Bool

Check the indentation contract of an abbreviated trace. Writing `col` for the column the
frame numbers end in, `⋮` markers sit at `col + 2`, every frame number is right-aligned to
`col`, and every `@ Module file:line` continuation starts at `col`. `col` is taken from the
first `⋮` line when there is one, so a frame indented for a different number width fails.
"""
function aligned(block::AbstractString)
    ls = split(block, '\n')
    indent(l) = length(match(r"^ *", l).match)
    omitted = findfirst(l -> contains(l, '⋮'), ls)
    col = if omitted === nothing
        frames = filter(l -> contains(l, FRAME), ls)
        isempty(frames) && return false
        maximum(l -> length(match(FRAME_NUMBER, l).match), frames)
    else
        indent(ls[omitted]) - 1
    end
    for l ∈ ls
        if contains(l, FRAME)
            length(match(FRAME_NUMBER, l).match) == col || return false
        elseif contains(l, '⋮')
            indent(l) == col + 1 || return false
        elseif startswith(l, r" *@ ")
            indent(l) == col - 1 || return false
        end
    end
    return true
end

const HIDDEN = "Some frames were hidden. Use `show(err)` to see complete trace."
const TRUNCATED_AND_HIDDEN =
    "Some type information was truncated. Some frames were hidden. " *
    "Use `show(err)` to see complete trace."

const PATH_SEP = "[/\\\\]"
regex_quote(s::AbstractString) = replace(s, r"[\\^$.|?*+()\[\]{}]" => s"\\\0")

#= Base names its own files relative to Julia's source tree rather than absolutely: a bare
file name from 1.14 on, a `./`-prefixed one before that. Write such a path as `./file.jl` and
either form matches. =#
function file_pattern(path::AbstractString)
    prefix, rest = startswith(path, "./") ? ("(\\." * PATH_SEP * ")?", path[3:end]) : ("", path)
    return prefix * replace(regex_quote(rest), '/' => PATH_SEP)
end

"""
    at(mod, path) -> Regex

Matches an `@ Module file.jl:12` location line, `path` written with `/` separators. A trailing
`[inlined]` is accepted, since whether Base inlines a given call is not something these tests
should pin down.
"""
at(mod::Union{AbstractString,Nothing}, path::AbstractString) =
    Regex("^ *@ " * (mod === nothing ? "" : regex_quote(mod) * " ") *
          file_pattern(path) * ":\\d+( \\[inlined\\])?\$")

"""
    at_inlined(mod, path) -> Regex

[`at`](@ref) for a frame that is always inlined, where the `[inlined]` marker is required.
Before 1.14 an inlined frame carried no module of its own, so the module is optional.
"""
at_inlined(mod::AbstractString, path::AbstractString) =
    Regex("^ *@ (" * regex_quote(mod) * " )?" * file_pattern(path) * ":\\d+ \\[inlined\\]\$")

"""
    omitted(modules...) -> Regex

Matches an `⋮ internal @ ...` summary naming exactly `modules`. Before 1.14 inlined frames
carried no module, which the summary reported as `Unknown`, so a trailing one is accepted.
"""
omitted(modules::AbstractString...) =
    Regex("^ *⋮ internal @ " * join(regex_quote.(modules), ", ") * "(, Unknown)?\$")

# 1.14 renders `Type{Any}` as `Core.TypeEgal{Any}`, so match `zero` by name alone
const ZERO_FRAME = r"(?m)^ *\[\d+\] zero\("
const ZERO_CALL = "zero("
