module AbbrvStackTracesREPLExt

__precompile__(false)

const REPL = Base.REPL_MODULE_REF[] # hack because can't otherwise get ref to REPL module without taking dependency

import Base:
    MainInclude

if VERSION ≥ v"1.11"
    REPL.repl_display_error(errio::IO, @nospecialize errval) = repl_display_error_abbrv(errio, errval)
end

if VERSION ≥ v"1.12-alpha"
    import REPL:
        call_on_backend
    function REPL.print_response(errio::IO, response, backend::Union{REPL.REPLBackendRef,Nothing}, show_value::Bool, have_color::Bool, specialdisplay::Union{AbstractDisplay,Nothing}=nothing)
        Base.sigatomic_begin()
        val, iserr = response
        while true
            try
                Base.sigatomic_end()
                if iserr
                    val = Base.scrub_repl_backtrace(val)
                    Base.istrivialerror(val) || setglobal!(Base.MainInclude, :err, val)
                    REPL.repl_display_error(errio, val)
                else
                    if val !== nothing && show_value
                        val2, iserr = if specialdisplay === nothing
                            # display calls may require being run on the main thread
                            call_on_backend(backend) do
                                Base.invokelatest(display, val)
                            end
                        else
                            call_on_backend(backend) do
                                Base.invokelatest(display, specialdisplay, val)
                            end
                        end
                        if iserr
                            println(errio, "Error showing value of type ", typeof(val), ":")
                            throw(val2)
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
                        setglobal!(Base.MainInclude, :err, excs)
                        REPL.repl_display_error(errio, excs)
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
else
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
