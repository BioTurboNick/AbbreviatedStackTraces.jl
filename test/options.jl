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
    @test occursin(ZERO_FRAME, full)
    @test !occursin('⋮', full)

    # ...unless asked, which is the only way to abbreviate away from a prompt
    abbrv = withenv("JULIA_STACKTRACE_ABBREVIATED" => "true") do
        trace_section(display_error_text(() -> sum([])))
    end
    @test occursin('⋮', abbrv)
    @test !occursin(ZERO_CALL, abbrv)
end

@testset "JULIA_STACKTRACE_MINIMAL" begin
    # Signatures dropped and the location folded onto the frame's own line
    tr = withenv("JULIA_STACKTRACE_MINIMAL" => "true") do
        lines(trace_block("sum([])"))
    end
    @test length(tr) == 4
    @test occursin(omitted("Base"), tr[2])
    #= `sum` takes keyword arguments, so the frame that survives is its `#sum#…` body method.
    Minimal mode has to name it after the function rather than after the method. =#
    @test occursin(r"^ *\[\d+\] sum @ Base (\.[/\\])?reducedim\.jl:\d+( \[inlined\])?$", tr[3])
    @test tr[4] == HIDDEN
end

minimal_kwfun(x; k = 1, j...) = sum([])
struct MinimalCallable{T} end
(::MinimalCallable{T})(x; k = 1) where {T} = sum([])

"The frames of `f()`'s backtrace that Julia compiled as keyword-argument body methods."
function kwargs_frames(f)
    bt = try
        f()
        nothing
    catch
        catch_backtrace()
    end
    bt === nothing && error("expected an exception")
    return filter(first.(Base.process_backtrace(stacktrace(bt)))) do frame
        m = AbbreviatedStackTraces.frame_method(frame)
        m isa Method && m.nkw > 0
    end
end

@testset "minimal mode names frames the way Base does" begin
    #= Minimal mode drops a frame's signature, not its name, so the name it prints has to be
    the one Base would use. Keyword-argument methods are the case worth pinning: they are
    compiled under a mangled `#f#123`, and Base does not name such a frame after the method
    either — it reads the function out of the signature. Whatever Base's full display prints,
    the minimal name must be the call it opens with. =#
    render(frame, f) = sprint(f, frame; context = :backtrace => true)
    checked = 0
    for f ∈ (() -> minimal_kwfun(1; k = 2, extra = 3), () -> MinimalCallable{Int}()(1; k = 2))
        for frame ∈ kwargs_frames(f)
            full = render(frame, Base.StackTraces.show_spec_linfo)
            mini = render(frame, AbbreviatedStackTraces.show_spec_linfo_minimal)
            @test startswith(full, mini * "(")
            @test !startswith(mini, '#')
            checked += 1
        end
    end
    #= Only 1.14 reaches this: before it, `process_backtrace` collapsed the body method into
    the plainly-named frame, so no mangled name ever arrived. Guard against the assertions
    above quietly becoming vacuous on the one version that needs them. =#
    VERSION < v"1.14.0-DEV" || @test checked > 0
end

@testset "JULIA_STACKTRACE_PUBLIC" begin
    # `zero` is public in Base, so its frame comes back even though Base is internal
    @test !occursin(ZERO_CALL, trace_block("sum([])"))
    trace = withenv("JULIA_STACKTRACE_PUBLIC" => "true") do
        trace_block("sum([])")
    end
    @test occursin(ZERO_FRAME, trace)
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
    @test occursin(ZERO_CALL, excluded) # still in Base, still not in reduce.jl
    @test occursin('⋮', excluded)
    @test aligned(excluded)
end
