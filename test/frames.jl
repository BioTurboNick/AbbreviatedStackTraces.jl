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
function compact(trace; minimal = false, cycles = NTuple{3, Int}[])
    io = IOBuffer()
    #= Only 1.13 and later pad frame numbers to the whole frame count rather than the entry
    count, and reserve a gutter for cycle brackets. Traces built here are short enough that
    Base would take the branch that skips cycle detection, so `cycles` stands in for what it
    would otherwise have found. =#
    layout = CYCLE_BRACKETS ?
        (; total_frames = sum(last, trace),
           repeated_cycles = cycles,
           max_nested_cycles = isempty(cycles) ?
               (any(x -> last(x) > 1, trace) ? 1 : 0) : 2) : (;)
    withenv("JULIA_STACKTRACE_MINIMAL" => string(minimal)) do
        AST.show_compact_backtrace(IOContext(io, :color => false), trace;
            print_linebreaks = false, layout...)
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

@testset "a cycle reaching past the trace" begin
    #= Base records a cycle's start and length against the frames it had collapsed so far, and
    that span can reach past either end of the trace it hands back — a recursion through `map`
    does it, and Base's own display then leaves the bracket hanging open. Whatever it renders,
    indexing the trace by that span must not run off the end. =#
    trace = Any[(frame(:only_f, "REPL[1]"), 1), (frame(:only_g, "REPL[1]"), 1)]
    past_end = compact(trace; cycles = [(2, 6, 61)])   # spans 2:7 of a 2-frame trace
    @test occursin("only_f", past_end)
    @test occursin("only_g", past_end)
    before_start = compact(trace; cycles = [(0, 3, 4)]) # starts below the first frame
    @test occursin("only_f", before_start)
    @test occursin("only_g", before_start)
end

@testset "a cycle spanning internal frames" begin
    #= Internal frames inside a cycle are dropped like any other, and the `⋮` standing in for
    them carries the bracket across. `hop_b` sits away from any user frame, so nothing else
    would keep it. =#
    hop(name) = (frame(name, "abstractarray.jl"), 1)
    trace = Any[(frame(:mapreduce_impl, "reduce.jl"), 1),
                (frame(:user_inner, "REPL[1]"), 1),
                hop(:hop_c), hop(:hop_b), hop(:hop_a),
                (frame(:user_outer, "REPL[1]"), 1),
                (frame(:tail_c, "client.jl"), 1), (frame(:tail_b, "client.jl"), 1),
                (frame(:tail_a, "client.jl"), 1),
                (frame(:user_caller, "REPL[1]"), 1)]

    # Without a cycle over it, `hop_b` is hidden like any other internal frame
    @test !occursin("hop_b", compact(trace))
    @test occursin('⋮', compact(trace))

    covered = compact(trace; cycles = [(2, 5, 50)])
    if CYCLE_BRACKETS
        @test !occursin("hop_b", covered)
        bracketed = [l for l ∈ split(covered, '\n') if startswith(l, r" [┌├│╰]")]
        # The bracket opens on the first frame of the cycle still shown and closes on the last
        @test occursin(r"^ ┌ *\[2\] user_inner$", first(bracketed))
        @test occursin(r"^ ╰─+ repeated 50 times$", last(bracketed))
        # The ⋮ standing in for what was dropped from the middle carries the bracket across
        @test any(l -> occursin(r"^ │ +⋮ internal", l), bracketed)
        # ...and the tail outside the cycle is abbreviated with no bracket at all
        @test occursin(r"(?m)^ {2,}⋮ internal", covered)
        @test !occursin("tail_b", covered)
    end
    @test aligned(covered)
end
