module AbbrvStackTracesREPLExt

__precompile__(false)

const REPL = Base.REPL_MODULE_REF[] # hack because can't otherwise get ref to REPL module without taking dependency

import Base:
    MainInclude

#= Overwriting the hook the REPL funnels error display through is enough; `print_response`
itself must be left alone. It ships a closure to the backend task via `call_on_backend`, and
`repl_backend_loop` calls that closure as a bare `f()` from a frame entered once at REPL
startup. Base's own closures were defined when REPL loaded, so they are always old enough;
one defined here is too new for that frame whenever the package is loaded at the prompt
rather than before the REPL starts, and displaying any value then fails with a world-age
`MethodError`. =#
if VERSION ≥ v"1.13.0-rc3"
    REPL.__repl_entry_display_error(errio::IO, @nospecialize errval) = repl_display_error_abbrv(errio, errval)
elseif VERSION ≥ v"1.11"
    REPL.repl_display_error(errio::IO, @nospecialize errval) = repl_display_error_abbrv(errio, errval)
else
    #= No such hook before 1.11, so `print_response` has to be overwritten wholesale. It
    predates `call_on_backend` and displays on this task, so no closure crosses over. =#
    function REPL.print_response(errio::IO, response, show_value::Bool, have_color::Bool, specialdisplay::Union{AbstractDisplay,Nothing}=nothing)
        Base.sigatomic_begin()
        val, iserr = response
        while true
            try
                Base.sigatomic_end()
                if iserr
                    val = Base.scrub_repl_backtrace(val)
                    Base.istrivialerror(val) || setglobal!(MainInclude, :err, val)
                    Base.invokelatest(repl_display_error_abbrv, errio, val)
                else
                    if val !== nothing && show_value
                        try
                            if specialdisplay === nothing
                                Base.invokelatest(display, val)
                            else
                                Base.invokelatest(display, specialdisplay, val)
                            end
                        catch
                            println(errio, "Error showing value of type ", typeof(val), ":")
                            rethrow()
                        end
                    end
                end
                break
            catch ex
                if iserr
                    println(errio) # an error during printing is likely to leave us mid-line
                    println(errio, "SYSTEM (REPL): showing an error caused an error")
                    try
                        excs = Base.scrub_repl_backtrace(current_exceptions())
                        setglobal!(MainInclude, :err, excs)
                        Base.invokelatest(repl_display_error, errio, excs)
                    catch e
                        # at this point, only print the name of the type as a Symbol to
                        # minimize the possibility of further errors.
                        println(errio)
                        println(errio, "SYSTEM (REPL): caught exception of type ", typeof(e).name.name,
                                " while trying to handle a nested exception; giving up")
                    end
                    break
                end
                val = current_exceptions()
                iserr = true
            end
        end
        Base.sigatomic_end()
        nothing
    end
end

function repl_display_error_abbrv(errio::IO, @nospecialize errval)
    # this will be set to true if types in the stacktrace are truncated
    limit_types_flag = Ref(false)
    # this will be set to false if frames in the stacktrace are not hidden
    hide_internal_frames_flag = Ref(true)
    
    errio = IOContext(errio, :stacktrace_types_limited => limit_types_flag, :compacttrace => hide_internal_frames_flag)
    Base.invokelatest(Base.display_error, errio, errval)
    if limit_types_flag[] || hide_internal_frames_flag[]
        limit_types_flag[] && print(errio, "Some type information was truncated. ")
        hide_internal_frames_flag[] && print(errio, "Some frames were hidden. ")
        print(errio, "Use `show(err)` to see complete trace.")
        println(errio)
    end
    return nothing
end


end
