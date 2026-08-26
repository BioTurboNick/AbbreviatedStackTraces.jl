#= Frame selection and compact rendering, driven by synthetic traces. A stack overflow is the
case that motivates these, and building the trace by hand both keeps the frame counts exact
and avoids deliberately overflowing the stack of the process running the tests. =#

using Base.StackTraces: StackFrame, top_level_scope_sym

frame(func, file) = StackFrame(func, Symbol(file), 1)
#= `foo() = foo()` recursing until it overflows: every frame is the user's, and
`process_backtrace` collapses them all into a single entry. =#
const OVERFLOW_TRACE = Any[(frame(:foo, "REPL[1]"), 79984)]

@testset "a function defined at the prompt is not the REPL top-level" begin
    #= Both name the same pseudo-file, and from 1.14 on they are spelled identically, so only
    being top-level outright may drop a frame. Otherwise a user's own function disappears
    whenever it is the last frame in the trace, which is exactly the stack-overflow case. =#
    @test AST.find_visible_frames(OVERFLOW_TRACE) == [1]

    # A real top-level frame is still dropped, and the frame below it kept
    with_toplevel = Any[(frame(:foo, "REPL[1]"), 1), (frame(top_level_scope_sym, "REPL[2]"), 1)]
    @test AST.find_visible_frames(with_toplevel) == [1]
end

"Render `trace` through the abbreviated display exactly as `show_backtrace` would."
function compact(trace; minimal = false)
    io = IOBuffer()
    # Only 1.13 and later pad frame numbers to the whole frame count rather than the entry count
    widths = CYCLE_BRACKETS ? (; total_frames = sum(last, trace)) : (;)
    withenv("JULIA_STACKTRACE_MINIMAL" => string(minimal)) do
        AST.show_compact_backtrace(IOContext(io, :color => false), trace;
            print_linebreaks = false, widths...)
    end
    return strip(String(take!(io)), ['\n', ' '])
end

@testset "repeated frames" begin
    out = lines(compact(OVERFLOW_TRACE))
    @test out[1] == "Stacktrace:"
    if CYCLE_BRACKETS
        #= 1.13 renders a repeat as a bracket in a gutter rather than an inline count, and pads
        the frame number to the width of the whole frame count — 79984, not the one entry the
        trace collapsed to. The closing rule runs out to that column, so its length pins the
        width down. =#
        @test length(out) == 4
        @test occursin(r"^ ┌ +\[1\] foo$", out[2])
        @test occursin(r"^ │ +@ REPL\[1\]:1$", out[3])
        @test out[4] == " ╰" * "─"^(ndigits(79984) + 2) * " repeated 79984 times"
    else
        @test length(out) == 3
        @test occursin(r"^ +\[1\] foo \(repeats 79984 times\)$", out[2])
        @test occursin(r"^ +@ REPL\[1\]:1$", out[3])
    end
    @test aligned(compact(OVERFLOW_TRACE))
end

@testset "a repeat reserves the gutter for every frame" begin
    #= The bracket needs a column to the left of the frame numbers, so the rest of the trace
    shifts over by one to keep the columns lined up. Without a repeat there is nothing to make
    room for. =#
    plain = Any[(frame(:inner, "REPL[1]"), 1), (frame(:outer, "REPL[1]"), 1)]
    repeated = Any[(frame(:inner, "REPL[1]"), 3), (frame(:outer, "REPL[1]"), 1)]
    function indent_of(block, want)
        line = only(l for l ∈ split(block, '\n') if occursin(want, l))
        return length(match(r"^ *", line).match)
    end

    shift = CYCLE_BRACKETS ? 1 : 0
    @test indent_of(compact(repeated), "outer") == indent_of(compact(plain), "outer") + shift
    @test aligned(compact(plain))
    @test aligned(compact(repeated))
end
