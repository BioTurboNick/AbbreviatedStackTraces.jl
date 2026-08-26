#= The environment variables documented in the README. `withenv` is enough to reach the fake
REPL because it runs in this same process. =#

"Render `f()`'s error the way a non-interactive session does, with no REPL involved."
function display_error_text(f)
    stack = try
        f()
        nothing
    catch
        Base.current_exceptions()
    end
    stack === nothing && error("expected an exception")
    io = IOBuffer()
    Base.display_error(IOContext(io, :color => false), stack)
    return String(take!(io))
end

@testset "JULIA_STACKTRACE_ABBREVIATED" begin
    # Outside the REPL nothing is hidden by default...
    full = trace_section(display_error_text(() -> sum([])))
    @test occursin(r"^ *\[1\] zero\(::Type\{Any\}\)$"m, full)
    @test !occursin('⋮', full)

    # ...unless asked, which is the only way to abbreviate away from a prompt
    abbrv = withenv("JULIA_STACKTRACE_ABBREVIATED" => "true") do
        trace_section(display_error_text(() -> sum([])))
    end
    @test occursin('⋮', abbrv)
    @test !occursin("zero(::Type{Any})", abbrv)
end

@testset "JULIA_STACKTRACE_MINIMAL" begin
    # Signatures dropped and the location folded onto the frame's own line
    tr = withenv("JULIA_STACKTRACE_MINIMAL" => "true") do
        lines(trace_block("sum([])"))
    end
    @test length(tr) == 4
    @test occursin(r"^ *⋮ internal @ Base, Unknown$", tr[2])
    @test occursin(r"^ *\[\d+\] sum @ Base \.[/\\]reducedim\.jl:\d+$", tr[3])
    @test tr[4] == HIDDEN
end

@testset "JULIA_STACKTRACE_PUBLIC" begin
    # `zero` is public in Base, so its frame comes back even though Base is internal
    @test !occursin("zero(::Type{Any})", trace_block("sum([])"))
    trace = withenv("JULIA_STACKTRACE_PUBLIC" => "true") do
        trace_block("sum([])")
    end
    @test occursin(r"^ *\[1\] zero\(::Type\{Any\}\)$"m, trace)
    @test occursin(at("Base", "./missing.jl"), lines(trace)[3])
    @test occursin(HIDDEN, trace)
    @test aligned(trace)
end

@testset "JULIA_DEBUG" begin
    # A named module is treated as user code...
    included = withenv("JULIA_DEBUG" => "Base") do
        trace_block("sum([])")
    end
    @test occursin("reduce_empty", included)
    @test occursin(at("Base", "./reduce.jl"), lines(included)[5])
    @test aligned(included)

    # ...and a `!`-prefixed file name is subtracted back out of it
    excluded = withenv("JULIA_DEBUG" => "Base,!reduce") do
        trace_block("sum([])")
    end
    @test !occursin("reduce_empty", excluded)
    @test occursin("zero(::Type{Any})", excluded) # still in Base, still not in reduce.jl
    @test occursin('⋮', excluded)
    @test aligned(excluded)
end
