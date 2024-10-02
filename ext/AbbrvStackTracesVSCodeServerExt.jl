module AbbrvStackTracesVSCodeServerExt

__precompile__(false)

@eval Main begin
    import .VSCodeServer:
        crop_backtrace,
        EvalErrorStack,
        display_repl_error,
        replcontext,
        unwrap_loaderror
    
    import Base:
        showerror

    import Base.StackTraces:
        stacktrace

    is_ide_support(path) = contains(path, r"[/\\].vscode[/\\]")

    replcontext(io, limit_types_flag, hide_internal_frames_flag) = IOContext(
        io,
        :limit => true,
        :displaysize => get(stdout, :displaysize, (60, 120)),
        :stacktrace_types_limited => limit_types_flag,
        :compacttrace => hide_internal_frames_flag
    )

    function display_repl_error(io, err, bt; unwrap = false)
        limit_types_flag = Ref(false)
        hide_internal_frames_flag = Ref(true)
    
        st = stacktrace(crop_backtrace(bt))
        printstyled(io, "ERROR: "; bold = true, color = Base.error_color())
        showerror(replcontext(io, limit_types_flag, hide_internal_frames_flag), err, st)
        if limit_types_flag[] || hide_internal_frames_flag[]
            limit_types_flag[] && print(io, "Some type information was truncated. ")
            hide_internal_frames_flag[] && print(io, "Some frames were hidden. ")
            print(io, "Use `show(err)` to see complete trace.")
            println(io)
        end
        println(io)
    end
    
    function display_repl_error(io, stack::EvalErrorStack; unwrap = false)
        limit_types_flag = Ref(false)
        hide_internal_frames_flag = Ref(true)
    
        printstyled(io, "ERROR: "; bold = true, color = Base.error_color())
        for (i, (err, bt)) in enumerate(reverse(stack.stack))
            i !== 1 && print(io, "\ncaused by: ")
            st = stacktrace(crop_backtrace(bt))
            showerror(replcontext(io, limit_types_flag, hide_internal_frames_flag), unwrap && i == 1 ? unwrap_loaderror(err) : err, st)
            println(io)
        end
    
        if limit_types_flag[] || hide_internal_frames_flag[]
            limit_types_flag[] && print(io, "Some type information was truncated. ")
            hide_internal_frames_flag[] && print(io, "Some frames were hidden. ")
            print(io, "Use `show(err)` to see complete trace.")
            println(io)
        end
    end
end

end