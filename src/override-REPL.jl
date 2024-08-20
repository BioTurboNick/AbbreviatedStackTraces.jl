__precompile__(false)

import REPL:
    print_response

import Base:
    MainInclude

function print_response(errio::IO, response, show_value::Bool, have_color::Bool, specialdisplay::Union{AbstractDisplay,Nothing}=nothing)
    Base.sigatomic_begin()
    val, iserr = response
    while true
        try
            Base.sigatomic_end()
            if iserr
                val = Base.scrub_repl_backtrace(val)
                if VERSION < v"1.10-alpha1"
                    Base.istrivialerror(val) || setglobal!(Main, :err, val)
                else
                    Base.istrivialerror(val) || setglobal!(MainInclude, :err, val)
                end
                Base.invokelatest(Base.display_error, errio, val, true)
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
                    if VERSION < v"1.10-alpha1"
                        setglobal!(Main, :err, excs)
                    else
                        setglobal!(MainInclude, :err, excs)
                    end
                    Base.invokelatest(Base.display_error, errio, excs)
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
