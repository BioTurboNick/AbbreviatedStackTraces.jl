try
    @eval Main begin
        import .VSCodeServer:
            crop_backtrace,
            display_repl_error,
            unwrap_loaderror
        
        import Base:
            showerror

        import Base.StackTraces:
            stacktrace

        is_ide_support(path) = contains(path, r"[/\\].vscode[/\\]")

        function display_repl_error(io, err, bt)
            ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, AbbreviatedStackTraces.ExceptionStack([(exception = err, backtrace = bt)]))
            st = stacktrace(VSCodeServer.crop_backtrace(bt))
            printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
            showerror(IOContext(io, :limit => true, :compacttrace => true), err, st)
            println(io)
        end
        function display_repl_error(io, stack::VSCodeServer.EvalErrorStack)
            printstyled(io, "ERROR: "; bold = true, color = Base.error_color())
            ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, AbbreviatedStackTraces.ExceptionStack(reverse(stack.stack)))
            for (i, (err, bt)) in enumerate(reverse(stack.stack))
                i !== 1 && print(io, "\ncaused by: ")
                st = stacktrace(crop_backtrace(bt))
                showerror(IOContext(io, :limit => true, :compacttrace => true), i == 1 ? unwrap_loaderror(err) : err, st)
                println(io)
            end
        end
    end
catch e
    if !isa(e, UndefVarError) || e.var != :VSCodeServer
        rethrow()
    end
end
