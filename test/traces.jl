#= Frame numbers and line numbers move whenever Base's internals move, so they are matched
loosely; the shape of the trace — which frames survive, which modules are named in the
`⋮ internal` summaries, and how it all lines up — is what these tests pin down. =#

@testset "sum([])" begin
    tr = lines(trace_block("sum([])"))
    @test length(tr) == 5
    @test tr[1] == "Stacktrace:"
    @test occursin(r"^ *⋮ internal @ Base, Unknown$", tr[2])
    @test occursin(r"^ *\[\d+\] sum\(a::Vector\{Any\}\)$", tr[3])
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
    @test occursin(r"^ *⋮ internal @ Base.Broadcast, Unknown$", tr[2])
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
    @test occursin(r"^ *⋮ internal @ Base, Unknown$", tr[2])
    @test occursin(r"^ *\[\d+\] sum$", tr[3])
    @test occursin(at(nothing, "./reducedim.jl"; suffix = " [inlined]"), tr[4])
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
    @test occursin(r"^ *⋮ internal @ Base, Unknown$", tr[2])
    @test occursin(r"^ *\[\d+\] sum$", tr[3])
    @test occursin(at(nothing, "./reducedim.jl"; suffix = " [inlined]"), tr[4])
    @test occursin(r"^ *⋮ internal @ Main, BenchmarkTools, Unknown$", tr[5])
    @test occursin(r"^ *\[\d+\] top-level scope$", tr[6])
    @test occursin(r"^ *@ .*[/\\]BenchmarkTools[/\\].*[/\\]execution\.jl:\d+$", tr[7])
    @test tr[8] == HIDDEN
    @test aligned(trace)
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
        @test occursin(r"(?m)^ *\[1\] zero\(::Type\{Any\}\)$", full)
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
