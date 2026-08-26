using Test

# REPL has to be loaded before AbbreviatedStackTraces for it to install its REPL hooks
using REPL
using AbbreviatedStackTraces

include("fakerepl.jl")

@testset "AbbreviatedStackTraces" begin
    include("overrides.jl")
    include("paths.jl")
    include("frames.jl")
    include("traces.jl")
    include("options.jl")
    include("at_prompt.jl")
end
