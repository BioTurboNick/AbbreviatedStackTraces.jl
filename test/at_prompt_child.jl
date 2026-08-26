#= Run by `at_prompt.jl` in a subprocess. AbbreviatedStackTraces is deliberately *not* loaded
here — the `using` happens at the fake prompt, which is the only way to get the package's
methods defined in a world newer than the REPL's own tasks. Prints the session transcript for
the parent to inspect. =#

using Test
using REPL

include("fakerepl.jl")

print(repl_output("using AbbreviatedStackTraces", "foo() = foo()", "sum([])"))
