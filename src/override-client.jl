__precompile__(false)

import Base:
    display_error,
    printstyled,
    scrub_repl_backtrace,
    show_exception_stack,
    stacktrace

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

function display_error(io::IO, stack::ExceptionStack, compacttrace::Bool = false)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    show_exception_stack(IOContext(io, :limit => true, :compacttrace => isinteractive() ? compacttrace : false), stack)
    println(io)
end
display_error(stack::ExceptionStack, compacttrace = false) = display_error(stderr, stack, compacttrace)
