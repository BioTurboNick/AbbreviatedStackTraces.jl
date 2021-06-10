# AbbreviatedStackTraces.jl

The goal of this is to demonstrate an improvement to the display of stack traces in the Julia REPL, associated with this PR: https://github.com/JuliaLang/julia/pull/40537

Chaining packages together, or particularly complex packages, can produce some nasty stack traces that fill the screen. This is a barrier to entry using Julia and can get in the way generally.

Here's an example of a stack trace by chaining BenchmarkTools and Plots:

```
]add https://github.com/BioTurboNick/AbbreviatedStackTraces.jl # to install (not in registry)
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
