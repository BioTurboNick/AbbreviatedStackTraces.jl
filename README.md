# AbbreviatedStackTraces.jl

The goal of this is to demonstrate an improvement to the display of stack traces in the Julia REPL, associated with this PR: https://github.com/JuliaLang/julia/pull/40537

Chaining packages together, or particularly complex packages, can produce some nasty stack traces that fill the screen. This is a barrier to entry using Julia and can get in the way generally.

Here's an example of a stack trace by chaining BenchmarkTools and Plots:

```
using BenchmarkTools, Plots
@btime plot([1,2,3], seriestype=:blah)
```
![image](https://user-images.githubusercontent.com/1438610/115907559-0c36b300-a437-11eb-87c3-ba314ab6db72.png)

It aims to find the stack frames of code you don't control and excludes them by default, except for the first frame into that package. In it's place, it lists the modules called in the intervening frames. The theory is that errors in your code are much more likely than errors inside Base, the Stdlibs, or published packages, so their internals are usually superfluous.

![image](https://user-images.githubusercontent.com/1438610/115982784-a0099b80-a56b-11eb-80dd-b715ed245f34.png)

The global `err` variable stores the last error and can show the full, original stack trace easily.
