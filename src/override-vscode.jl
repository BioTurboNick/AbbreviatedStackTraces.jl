__precompile__(false)

try
    if isdefined(Main, :VSCodeServer)
        @eval (@__MODULE__) begin
            is_ide_support(path) = contains(path, r"[/\\].vscode[/\\]")
        end
    end
    @eval Main begin
        import .VSCodeServer:
            crop_backtrace,
            display_repl_error,
            unwrap_loaderror
        
        import Base:
            showerror

        import Base.StackTraces:
            stacktrace

        function display_repl_error(io, err, bt)
            st = stacktrace(VSCodeServer.crop_backtrace(bt))
            printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
            showerror(IOContext(io, :limit => true, :compacttrace => true), err, st)
            println(io)
        end
        function display_repl_error(io, stack::VSCodeServer.EvalErrorStack)
            printstyled(io, "ERROR: "; bold = true, color = Base.error_color())
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
