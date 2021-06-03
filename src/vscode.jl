try
@eval Main begin
import .VSCodeServer:
    display_repl_error,
    crop_backtrace

function display_repl_error(io, err, bt)
    ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, AbbreviatedStackTraces.ExceptionStack([(exception = err, backtrace = bt)]))
    st = stacktrace(VSCodeServer.crop_backtrace(bt))
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    showerror(IOContext(io, :limit => true, :compacttrace => true), err, st)
    println(io)
end
end
catch e
    if !isa(e, UndefVarError) || e.var != :VSCodeServer
        rethrow()
    end
end
