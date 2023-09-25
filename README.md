# AbbreviatedStackTraces.jl

The goal of this is to demonstrate an improvement to the display of stack traces in the Julia REPL, associated with this PR: https://github.com/JuliaLang/julia/pull/40537

## Rationale

Julia's stacktraces are often too long to be practical for most users. This can form a barrier to entry and become an annoyance.

So how can we maximize the utility of the stack traces for the common case?

My philosophy is this: 95% of the time, a given exception is due to a mistake in your own code. The probability of the exception being due to a mistake in a well-used dependency is much lower, and the probability of the exception being due to a mistake in Base is even smaller. The probability of an exception being due to a mistake in the compiler is infinitesimal (but nonzero).

Thus, the highest value stack frames, the majority of the time, are those relating to code you have written or are actively developing. The stack frames between your call into a foreign method and the frame where the validation occurs is usually irrelevant to you. And for composed functions, the internal frames between the call into a foreign function and where it emerges back into your code also doesn't usually matter. Those frames are implementation details that don't make a difference to whether *your* code works.

Which raised the question: what counts as "your" code?

I think clearly these sources can be assumed to not be your code, and more likely stable:
 - Julia Base
 - Julia Stdlibs
 - Dependencies acquired using Pkg `add`

Whereas these sources are "yours":
 - Activated local package
 - Code defined in the REPL
 - Dependencies acquired using Pkg `dev`
 - Modules or files matching `ENV["JULIA_DEBUG"]` (file basename and/or module names; comma-separated, `!` to exclude)

All frames originating from "your" code are shown by default, as well as the immediate next frame to show what function your code called. This information should be sufficient in most cases to understand that you made a mistake, and where that mistake was located. Note that this only works by default in interactive usage. Running unit tests (e.g. via `pkg>test`) or execution on distributed processes will show the full trace. This behavior can be customized via the [options](#options) below.

But in the rarer case where the issue was *not* in your code, the full trace can be retrieved from the `err` global variable.

## Options
* `ENV["JULIA_STACKTRACE_ABBREVIATED"] = true` enables abbreviated stack traces for all traces, not just those originating from an interactive session
* `ENV["JULIA_STACKTRACE_MINIMAL"] = true` omits type information for a one-line-per-frame minimal variant (see below)
* `ENV["JULIA_STACKTRACE_PUBLIC"] = true` will re-insert all functions from a module's public API (part of `names(module)`; Julia < 1.11, this will just be exported names)

## startup.jl and VSCode
Unfortunately, startup.jl is executed before VSCodeServer loads, which means the appropriate methods won't be overwritten.
Some workarounds are discussed here: https://github.com/BioTurboNick/AbbreviatedStackTraces.jl/issues/38

## Examples

Here's an example of a stack trace by chaining BenchmarkTools and Plots:

```
]add AbbreviatedStackTraces
using AbbreviatedStackTraces # over-writes error-related `Base` methods
using BenchmarkTools, Plots
@btime plot([1,2,3], seriestype=:blah)
```

<img width="848" alt="image" src="https://github.com/BioTurboNick/AbbreviatedStackTraces.jl/assets/1438610/7d32ab8d-ff92-47d1-93b1-d683edc6cb85">

It aims to find the stack frames of code you don't control and excludes them by default, except for the first frame into that package. In it's place, it lists the modules called in the intervening frames. The theory is that errors in your code are much more likely than errors inside Base, the Stdlibs, or published packages, so their internals are usually superfluous.

<img width="736" alt="image" src="https://github.com/BioTurboNick/AbbreviatedStackTraces.jl/assets/1438610/a03ff4ca-9113-4546-9269-00526b7323b4">

(Note: italics only works on Julia 1.10+)

The global `err` variable stores the last error and can show the full, original stack trace easily.

You can also add back functions with public (Julia 1.11) or exported (Julia 1.9, 1.10) names by setting `ENV["JULIA_STACKTRACE_PUBLIC"] = true`.

<img width="737" alt="image" src="https://github.com/BioTurboNick/AbbreviatedStackTraces.jl/assets/1438610/66b77163-e3a1-424a-9c28-7df52caa1ebb">

There is an optional minimal display available, accessed by setting `ENV["JULIA_STACKTRACE_MINIMAL"] = true`.

<img width="838" alt="image" src="https://github.com/BioTurboNick/AbbreviatedStackTraces.jl/assets/1438610/9379b2a9-7880-4122-8727-64cd6c5fed18">



Here's an example a beginner might readily run into:

<img width="845" alt="image" src="https://github.com/BioTurboNick/AbbreviatedStackTraces.jl/assets/1438610/b6af91a2-bff2-4a0f-91fd-c33b8727e165">

**Yikes!**

With this package:

<img width="845" alt="image" src="https://github.com/BioTurboNick/AbbreviatedStackTraces.jl/assets/1438610/ec413046-bb1e-43e6-bc93-ca29852a69c7">

**Much better!**
