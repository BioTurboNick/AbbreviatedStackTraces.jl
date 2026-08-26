#= Frame numbers, line numbers, signatures and inlining decisions all move whenever Base's
internals move, so they are matched loosely; the shape of the trace — which frames survive,
which modules are named in the `⋮ internal` summaries, and how it all lines up — is what these
tests pin down. =#

@testset "sum([])" begin
    tr = lines(trace_block("sum([])"))
    @test length(tr) == 5
    @test tr[1] == "Stacktrace:"
    @test occursin(omitted("Base"), tr[2])
    @test occursin(r"^ *\[\d+\] sum\(a::Vector\{Any\}", tr[3])
    @test occursin(at("Base", "./reducedim.jl"), tr[4])
    @test tr[5] == HIDDEN
    @test aligned(trace_block("sum([])"))
end

@testset "broadcasting" begin
    #= `materialize` is the frame a user cares about in a broadcast failure, and the package
    keeps it even though every frame in the trace belongs to Base. The signature is long
    enough to trip type truncation, which the REPL reports separately. =#
    tr = lines(trace_block("1 .+ [2,\"\"]"))
    @test length(tr) == 5
    @test tr[1] == "Stacktrace:"
    @test occursin(omitted("Base.Broadcast"), tr[2])
    @test occursin(r"^ *\[\d+\] materialize\(bc::Base\.Broadcast\.Broadcasted\{", tr[3])
    @test occursin("…", tr[3]) # type parameters truncated
    @test occursin(at("Base.Broadcast", "./broadcast.jl"), tr[4])
    @test tr[5] == TRUNCATED_AND_HIDDEN
    @test aligned(trace_block("1 .+ [2,\"\"]"))
end

@testset "user code in the REPL" begin
    # The function the user defined is user code; what it called into is shown, nothing below
    tr = lines(trace_block("f() = sum([])", "f()"))
    @test length(tr) == 7
    @test occursin(omitted("Base"), tr[2])
    @test occursin(r"^ *\[\d+\] sum\b", tr[3])
    @test occursin(at_inlined("Base", "./reducedim.jl"), tr[4])
    @test occursin(r"^ *\[\d+\] f\(\)$", tr[5])
    @test occursin(at("Main", "./REPL[1]"), tr[6])
    @test tr[7] == HIDDEN
    @test aligned(trace_block("f() = sum([])", "f()"))
end

@testset "macro expanded into Main from package code" begin
    #= `@btime` splices its harness into Main but the frames live in BenchmarkTools' files,
    so they are internal despite being in Main. What survives is the frame the harness called
    into and the top-level frame BenchmarkTools evaluates in. =#
    trace = trace_block("using BenchmarkTools", "@btime sum([])")
    tr = lines(trace)
    @test length(tr) == 8
    @test occursin(omitted("Base"), tr[2])
    @test occursin(r"^ *\[\d+\] sum\b", tr[3])
    @test occursin(at_inlined("Base", "./reducedim.jl"), tr[4])
    @test occursin(omitted("Main", "BenchmarkTools"), tr[5])
    @test occursin(r"^ *\[\d+\] top-level scope$", tr[6])
    @test occursin(r"^ *@ .*[/\\]BenchmarkTools[/\\].*[/\\]execution\.jl:\d+$", tr[7])
    @test tr[8] == HIDDEN
    @test aligned(trace)
end

# `@ Main <this file>:12`, without the module when the frame was inlined (before 1.14)
const HERE = Regex("^ *│? *@ (Main )?.*" * regex_quote(basename(@__FILE__)) * ":\\d+( \\[inlined\\])?\$")

#= A user → Base → user call chain. Defined here rather than typed at the prompt so the frames
come from a file, which is the ordinary case; a recursive self-reference also needs a settled
world age, which 1.12+ warns about otherwise. =#
chain_inner(x) = sum([])
chain_middle(v) = map(chain_inner, v)
chain_outer() = chain_middle([1])
recurse(n) = n == 0 ? sum([]) : recurse(n - 1)

@testset "user code kept across internal frames" begin
    #= Every user frame survives, each contiguous run of them keeps the one frame below it to
    show what that run called into, and the internal frames separating the runs collapse into
    a `⋮` of their own. =#
    trace = trace_block("chain_outer()")
    tr = lines(trace)
    @test length(tr) == 14
    @test occursin(omitted("Base"), tr[2])
    @test occursin(r"^ *\[\d+\] sum\b", tr[3]) # what chain_inner called into
    @test occursin(at_inlined("Base", "./reducedim.jl"), tr[4])
    @test occursin(r"^ *\[\d+\] chain_inner\b", tr[5])
    @test occursin(HERE, tr[6])
    @test occursin(omitted("Base"), tr[7]) # map's internals
    @test occursin(r"^ *\[\d+\] map\b", tr[8]) # what chain_middle called into
    @test occursin(at_inlined("Base", "./abstractarray.jl"), tr[9])
    @test occursin(r"^ *\[\d+\] chain_middle\b", tr[10])
    @test occursin(HERE, tr[11])
    @test occursin(r"^ *\[\d+\] chain_outer\(\)$", tr[12])
    @test occursin(HERE, tr[13])
    @test tr[14] == HIDDEN
    @test aligned(trace)
end

@testset "deep recursion" begin
    #= 61 frames of `recurse` push the trace past `BIG_STACKTRACE_SIZE`, which is where Base's
    own display switches to cycle detection. An abbreviated trace collapses the repeat itself,
    and renders it the way the running Julia does — bracketed from 1.13 on — alongside the `⋮`
    standing in for the Base frames below it. =#
    trace = trace_block("recurse(60)")
    tr = lines(trace)
    @test occursin(omitted("Base"), tr[2])
    @test occursin(r"^ *\[\d+\] sum\b", tr[3])
    @test occursin(at_inlined("Base", "./reducedim.jl"), tr[4])
    if CYCLE_BRACKETS
        @test length(tr) == 8
        @test occursin(r"^ ┌ *\[\d+\] recurse\(n::Int64\)$", tr[5])
        @test occursin(HERE, tr[6])
        @test occursin(r"^ ╰─* repeated 61 times$", tr[7])
        @test tr[8] == HIDDEN
    else
        @test length(tr) == 7
        @test occursin(r"^ *\[\d+\] recurse\(n::Int64\) \(repeats 61 times\)$", tr[5])
        @test occursin(HERE, tr[6])
        @test tr[7] == HIDDEN
    end
    @test aligned(trace)
end

#= Mutual recursion, so the repeating unit is a pair of frames rather than one frame. 101 trips
round puts the trace past `BIG_STACKTRACE_SIZE`, which is what makes Base go looking for
cycles. `nest_inner` recurses on `k` as well, giving a cycle nested inside a cycle. =#
cycle_a(n) = cycle_b(n - 1)
cycle_b(n) = n < 0 ? error() : cycle_a(n)
nest_outer(n) = n < 0 ? error() : nest_inner(n, 2)
nest_inner(n, k) = k == 0 ? nest_outer(n - 1) : nest_inner(n, k - 1)

@testset "multi-frame cycles" begin
    tr = lines(trace_block("cycle_a(100)"))
    @test occursin(r"^ *\[1\] error\(\)$", tr[2])
    @test occursin(at("Base", "./error.jl"), tr[3])
    if CYCLE_BRACKETS
        #= `┌` opens the cycle on the first frame of the repeating unit, `├` carries it through
        the rest, and `╰` closes with the count. Frame numbers count every repetition, so the
        second member is [3] and anything after the cycle jumps past all 202 of them. =#
        @test occursin(r"^ ┌ *\[2\] cycle_b\(n::Int64\)$", tr[4])
        @test occursin(HERE, tr[5])
        @test occursin(r"^ ├ *\[3\] cycle_a\(n::Int64\)$", tr[6])
        @test occursin(HERE, tr[7])
        @test occursin(r"^ ╰─+ repeated 101 times$", tr[8])
        @test length(tr) == 8
    else
        #= Before 1.13 a trace this long short-circuits to Base's `show_reduced_backtrace`,
        which has its own notation for a repeated run and abbreviates nothing. =#
        @test occursin(r"the (last|above) 2 lines are repeated 100 more times", string(tr))
    end
    @test aligned(trace_block("cycle_a(100)"))
end

@testset "nested cycles" begin
    tr = lines(trace_block("nest_outer(60)"))
    @test occursin(r"^ *\[1\] error\(\)$", tr[2])
    if CYCLE_BRACKETS
        # The inner cycle opens a second gutter column and closes inside the outer one
        @test occursin(r"^ ┌ *\[2\] nest_outer\(n::Int64\)$", tr[4])
        @test occursin(r"^ ├┌ *\[3\] nest_inner\(n::Int64, k::Int64\)$", tr[6])
        @test occursin(r"^ │╰─+ repeated 3 times$", tr[8])
        @test occursin(r"^ ╰─+ repeated 61 times$", tr[9])
        # The frame the recursion unwound to is numbered past every repetition
        @test occursin(r"^ *\[2[0-9]{2}\] nest_outer\(n::Int64\)$", tr[10])
    else
        # Base's pre-1.13 reduced display, as above
        @test occursin(r"lines are repeated \d+ more times", string(tr))
    end
    @test aligned(trace_block("nest_outer(60)"))
end

@testset "show(err) restores the full trace" begin
    out = repl_output("sum([])", "show(err)")
    i = findlast("1-element ExceptionStack:", out)
    @test i !== nothing
    if i !== nothing
        full = strip(out[first(i):end])
        # Frames numbered consecutively from 1, with nothing elided between them
        numbers = [parse(Int, m[1]) for m ∈ eachmatch(r"(?m)^ *\[(\d+)\] ", full)]
        @test numbers == 1:length(numbers)
        @test length(numbers) > 5
        @test occursin(ZERO_FRAME, full)
        @test !occursin('⋮', full)
        @test !occursin(HIDDEN, full)
    end
end

@testset "exception stacks" begin
    # The package overrides `show_exception_stack`, so check a nested error still renders
    block = error_block("try; sum([]); catch; error(\"wrapped\"); end")
    @test startswith(block, "ERROR: wrapped")
    @test occursin("\ncaused by: MethodError", block)
    @test occursin(r"^ *\[\d+\] error\(s::String\)$"m, block)
    #= Note: the `caused by:` trace is currently printed in full rather than abbreviated,
    because the outer trace hid nothing and so cleared the flag that requests abbreviation. =#
end
