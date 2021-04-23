module AbbreviatedStackTraces

import Base:
    StackTraces.top_level_scope_sym,
    StackFrame,
    show_backtrace,
    show_reduced_backtrace,
    show_full_backtrace,
    StackTraces.is_top_level_frame,
    STACKTRACE_FIXEDCOLORS,
    STACKTRACE_MODULECOLORS,
    BIG_STACKTRACE_SIZE,
    stacktrace_linebreaks,
    scrub_repl_backtrace,
    print_stackframe,
    process_backtrace,
    show,
    showerror

struct ExceptionInfo
    error::Exception
    stack::Vector{StackFrame}
end

show(io::IO, ex::ExceptionInfo) = display_full_error(io, [(ex.error, ex.stack)])

function display_full_error(io::IO, stack::Vector)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    show_full_exception_stack(IOContext(io, :limit => true), stack)
    println(io)
end

function show_full_exception_stack(io::IO, stack::Vector)
    # Display exception stack with the top of the stack first.  This ordering
    # means that the user doesn't have to scroll up in the REPL to discover the
    # root cause.
    nexc = length(stack)
    for i = nexc:-1:1
        if nexc != i
            printstyled(io, "\ncaused by: ", color=error_color())
        end
        exc, bt = stack[i]
        showerror(io, exc, bt; backtrace = bt!==nothing, compacttrace = false)
        i == 1 || println(io)
    end
end

function showerror(io::IO, ex, bt; backtrace=true, compacttrace=true)
    compacttrace && ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, ExceptionInfo(ex, bt))
    try
        showerror(io, ex)
    finally
        backtrace && show_backtrace(io, bt, compacttrace)
    end
end

function Base.show_backtrace(io::IO, t::Vector, compacttrace = true)
    if haskey(io, :last_shown_line_infos)
        empty!(io[:last_shown_line_infos])
    end

    # t is a pre-processed backtrace (ref #12856)
    if t isa Vector{Any}
        filtered = t
    else
        filtered = process_backtrace(t)
    end
    isempty(filtered) && return

    if length(filtered) == 1 && StackTraces.is_top_level_frame(filtered[1][1])
        f = filtered[1][1]::StackFrame
        if f.line == 0 && f.file === Symbol("")
            # don't show a single top-level frame with no location info
            return
        end
    end

    if length(filtered) > BIG_STACKTRACE_SIZE
        show_reduced_backtrace(IOContext(io, :backtrace => true), filtered)
        return
    end

    try invokelatest(update_stackframes_callback[], filtered) catch end
    # process_backtrace returns a Vector{Tuple{Frame, Int}}
    if compacttrace
        show_compact_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
    else
        show_full_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
    end
    return
end

function show_compact_backtrace(io::IO, trace::Vector; print_linebreaks::Bool)
    #= Show the lowest stackframe and display a message telling user how to
    retrieve the full trace =#

    num_frames = length(trace)
    ndigits_max = ndigits(num_frames)

    modulecolordict = copy(STACKTRACE_FIXEDCOLORS)
    modulecolorcycler = Iterators.Stateful(Iterators.cycle(STACKTRACE_MODULECOLORS))

    function print_omitted_modules(i, j)
        # Find modules involved in intermediate frames and print them
        modules = filter(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[i:j]))
        length(modules) > 0 || return
        print(io, repeat(' ', ndigits_max + 2))
        for m ∈ modules
            modulecolor = get_modulecolor!(modulecolordict, m, modulecolorcycler)
            printstyled(io, m, color = modulecolor)
            print(io, " ")
        end
        println(io)
    end

    # find all frames that aren't in Julia base, stdlib, or an added package
    is = findall(trace) do frame
        file = String(frame[1].file)
        !contains(file, r"[/\\].julia[/\\]packages[/\\]|[/\\]julia[/\\]stdlib") &&
        (!startswith(file, r".[/\\]") || startswith(file, r".[/\\]REPL")) ||
        (frame[1].func == top_level_scope_sym)
    end

    # include one frame lower
    is = filter(>(0), sort(union(is, is .- 1)))

    if length(is) > 0
        println(io, "\nStacktrace:")

        if is[1] > 1
            print_omitted_modules(1, is[1])
            println(io, repeat(' ', ndigits_max + 2) * "⋮")
        end

        lasti = first(is)
        @views for i ∈ is
            if i > lasti + 1
                println(io, repeat(' ', ndigits_max + 2) * "⋮")
                print_omitted_modules(lasti + 1, i - 1)
                println(io, repeat(' ', ndigits_max + 2) * "⋮")
            end
            print_stackframe(io, i, trace[i][1], trace[i][2], ndigits_max, modulecolordict, modulecolorcycler)
            if i < num_frames
                println(io)
                print_linebreaks && println(io)
            end
            lasti = i
        end
    end

    length(trace) > length(is) && print(io, "\nUse `err` to retrieve the full stack trace.")
end

function get_modulecolor!(modulecolordict, m, modulecolorcycler)
    if m !== nothing
        while parentmodule(m) !== m
            pm = parentmodule(m)
            pm == Main && break
            m = pm
        end
        if !haskey(modulecolordict, m)
            modulecolordict[m] = popfirst!(modulecolorcycler)
        end
        return modulecolordict[m]
    else
        return :default
    end
end

end