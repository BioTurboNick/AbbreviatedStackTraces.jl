__precompile__(false)

import Base:
    scrub_repl_backtrace,
    stacktrace

if VERSION ≥ v"1.12-alpha"
    function scrub_repl_backtrace(bt)
        if bt !== nothing && !(bt isa Vector{Any}) # ignore our sentinel value types
            bt = bt isa Vector{StackFrame} ? copy(bt) : stacktrace(bt)
            # remove REPL-related frames from interactive printing
            eval_ind = findlast(frame -> !frame.from_c && startswith(String(frame.func), "__repl_entry"), bt)
            # sysimages may drop debug info and won't have inlined frames present in the backtrace
            # in that case, `eval` may be dropped, but `eval_user_input` should be present
            # NOTE - unsure if still true with `__repl_entry` functions
            eval_ind === nothing && (eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval_user_input, bt))
            eval_ind === nothing || deleteat!(bt, eval_ind:length(bt))
        end
        return bt
    end
else
    function scrub_repl_backtrace(bt)
        if bt !== nothing && !(bt isa Vector{Any}) # ignore our sentinel value types
            bt = bt isa Vector{StackFrame} ? copy(bt) : stacktrace(bt)
            # remove REPL-related frames from interactive printing
            eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval, bt)
            # sysimages may drop debug info and won't have inlined frames present in the backtrace
            # in that case, `eval` may be dropped, but `eval_user_input` should be present
            eval_ind === nothing && (eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval_user_input, bt))
            eval_ind === nothing || deleteat!(bt, eval_ind:length(bt))
        end
        return bt
    end
end
