#= Loading the package at the prompt puts its methods in a world newer than the REPL's own
tasks, which is what exposed the `print_response` override: the closure it shipped to the
backend was too new for the frame that calls it, and displaying any value failed. The rest of
the suite cannot reach this, since it loads the package before starting a REPL, so this case
needs a subprocess of its own. =#

@testset "package loaded at the prompt" begin
    child = joinpath(@__DIR__, "at_prompt_child.jl")
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $child`
    out = try
        read(setenv(cmd, "JULIA_LOAD_PATH" => get(ENV, "JULIA_LOAD_PATH", "@:@v#.#:@stdlib")), String)
    catch err
        err isa ProcessFailedException ? "subprocess failed: $err" : rethrow()
    end

    # Defining a function still displays its value rather than a world-age MethodError
    @test occursin("foo (generic function with 1 method)", out)
    @test !occursin("Error showing value", out)
    @test !occursin("world age", out)

    # ...and traces raised at that prompt are still abbreviated
    @test occursin('⋮', out)
    @test occursin(HIDDEN, out)
    trace = occursin("\nStacktrace:", out) ? trace_section(out) : out
    @test occursin(r"^ *\[\d+\] sum\b"m, trace)
    @test aligned(trace)
end
