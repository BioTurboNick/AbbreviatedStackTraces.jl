__precompile__(false)

import Base:
    scrub_repl_backtrace,
    stacktrace

#= Base cuts an interactive trace at its own entry point, and only started looking for the
REPL's `__repl_entry` functions in 1.12; before that it cut at `eval`. This override
back-ports that. Both entry points are checked because `__repl_entry` reportedly appeared in
some 1.11 patch releases (see 31393d6), though not in 1.11.9.

From 1.12 on Base needs no help here, and 1.14's version is better than anything this package
would supply — it scrubs script entry points too, and drops the `eval`/`include` machinery
left above the cut — so it is deliberately left alone. =#
if VERSION < v"1.12-alpha"
    function scrub_repl_backtrace(bt)
        if bt !== nothing && !(bt isa Vector{Any}) # ignore our sentinel value types
            bt = bt isa Vector{StackFrame} ? copy(bt) : stacktrace(bt)
            # remove REPL-related frames from interactive printing
            eval_ind = findlast(frame -> !frame.from_c && startswith(String(frame.func), "__repl_entry"), bt)
            eval_ind === nothing && (eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval, bt))
            # sysimages may drop debug info and won't have inlined frames present in the backtrace
            # in that case, `eval` may be dropped, but `eval_user_input` should be present
            eval_ind === nothing && (eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval_user_input, bt))
            eval_ind === nothing || deleteat!(bt, eval_ind:length(bt))
        end
        return bt
    end
end
