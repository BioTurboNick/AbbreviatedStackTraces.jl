#= The package works by overwriting methods in Base and REPL. Nothing else in the suite can
mean anything if those overwrites silently stop landing — which is exactly how each new Julia
release has broken the package, by renaming or re-signaturing the function being overwritten.
=#

owner(f, types) = nameof(which(f, types).module)

@testset "Base overrides installed" begin
    @test owner(Base.show_backtrace, (IO, Vector)) === :AbbreviatedStackTraces
    @test owner(Base.show_exception_stack, (IO, Base.ExceptionStack)) === :AbbreviatedStackTraces
    #= `scrub_repl_backtrace` is overridden only where Base cuts the trace in the wrong place.
    From 1.12 on Base's own is at least as good — 1.14's is better — so it is left alone. =#
    @test owner(Base.scrub_repl_backtrace, (Any,)) ===
        (VERSION < v"1.12-alpha" ? :AbbreviatedStackTraces : :Base)
end

@testset "REPL hook installed" begin
    #= Whichever function the REPL funnels error display through, it has to reach
    `repl_display_error_abbrv`; that is what installs the `:compacttrace` flag. =#
    if VERSION ≥ v"1.13.0-rc3"
        @test owner(REPL.__repl_entry_display_error, (IO, Any)) === :AbbrvStackTracesREPLExt
    elseif VERSION ≥ v"1.11"
        @test owner(REPL.repl_display_error, (IO, Any)) === :AbbrvStackTracesREPLExt
    else
        @test owner(REPL.print_response, (IO, Any, Bool, Bool)) === :AbbrvStackTracesREPLExt
    end
end
