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

All frames originating from "your" code are shown by default, as well as the immediate next frame to show what function your code called. This information should be sufficient in most cases to understand that you made a mistake, and where that mistake was located. Note that if you run tests (e.g. via `pkg>test`) on "your" code, that full stack traces will be shown and this can be customized via the [options](#options) below.

But in the rarer case where the issue was *not* in your code, the full trace can be retrieved from the `err` global variable.

## Options
* `ENV["JULIA_STACKTRACE_ABBREVIATED"] = true` enables abbreviated stack traces for all traces, not just those originating from an interactive session
* `ENV["JULIA_STACKTRACE_MINIMAL"] = true` omits type information for a one-line-per-frame minimal variant (see below)

## Examples

Here's an example of a stack trace by chaining BenchmarkTools and Plots:

```
]add AbbreviatedStackTraces
using AbbreviatedStackTraces # over-writes error-related `Base` methods
using BenchmarkTools, Plots
@btime plot([1,2,3], seriestype=:blah)
```
![image](https://user-images.githubusercontent.com/1438610/115907559-0c36b300-a437-11eb-87c3-ba314ab6db72.png)

It aims to find the stack frames of code you don't control and excludes them by default, except for the first frame into that package. In it's place, it lists the modules called in the intervening frames. The theory is that errors in your code are much more likely than errors inside Base, the Stdlibs, or published packages, so their internals are usually superfluous.

![image](https://user-images.githubusercontent.com/1438610/116329328-1dfeba00-a799-11eb-8b86-f5c28e5b78e0.png)

The global `err` variable stores the last error and can show the full, original stack trace easily.

There is an optional minimal display available, accessed by setting `ENV["JULIA_STACKTRACE_MINIMAL"] = true`.
![image](https://user-images.githubusercontent.com/1438610/116329297-0b848080-a799-11eb-9d71-32650092b3a5.png)




Here's an example a beginner might readily run into:
![image](https://user-images.githubusercontent.com/1438610/121451945-8a5e0300-c96c-11eb-9070-d431b1cadc56.png)

**Yikes!**

With this package:
![image](https://user-images.githubusercontent.com/1438610/121452028-b4172a00-c96c-11eb-961b-300cbcbf5ad9.png)

**Much better!**
