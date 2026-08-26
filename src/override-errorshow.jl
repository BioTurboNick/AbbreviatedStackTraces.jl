__precompile__(false)

import Base:
    BIG_STACKTRACE_SIZE,
    contractuser,
    ExceptionStack,
    Filesystem,
    fixup_stdlib_path,
    invokelatest,
    print_module_path_file,
    printstyled,
    print_stackframe,
    process_backtrace,
    RefValue,
    show,
    show_backtrace,
    show_exception_stack,
    showerror,
    StackFrame,
    stacktrace_contract_userdir,
    stacktrace_expand_basepaths,
    stacktrace_linebreaks,
    update_stackframes_callback,
    StackTraces

if VERSION ≥ v"1.13.0-rc3"
    # 1.13 replaced `show_full_backtrace`/`show_reduced_backtrace` with a single
    # `show_processed_backtrace`, preceded by a separate cycle-detection pass
    import Base:
        _backtrace_find_and_remove_cycles,
        show_processed_backtrace

    function show_backtrace(io::IO, t::Vector; prefix = nothing)
        if haskey(io, :last_shown_line_infos)
            empty!(io[:last_shown_line_infos])
        end

        hide_internal_frames_flag = get(io, :compacttrace, nothing)
        if hide_internal_frames_flag isa RefValue{Bool}
            hide_internal_frames = hide_internal_frames_flag[]
            hide_internal_frames_flag[] = false # in case of early return
        else
            hide_internal_frames = false
        end

        # Process backtrace if it has not yet been. A processed backtrace is a Vector{Any}
        # with elements of type Tuple{StackFrame, Int}. (ref #12856)
        if t isa Vector{Any} && (length(t) == 0 || t[1] isa Tuple{StackFrame,Int})
            filtered = t
        else
            # t is a raw trace requiring lookup
            if t isa Vector{<:Union{Base.InterpreterIP,Ptr{Cvoid}}}
                frametrace = stacktrace(t)
            else
                frametrace = t
            end
            filtered = process_backtrace(frametrace)
        end
        isempty(filtered) && return

        nframes = sum(last(x) for x ∈ filtered)

        # don't show a single top-level frame with no location info
        if nframes == 1 && StackTraces.is_top_level_frame(filtered[1][1])
            f = filtered[1][1]::StackFrame
            if f.line == 0 && f.file === Symbol("")
                return
            end
        end

        # restore
        if hide_internal_frames_flag isa RefValue{Bool}
            hide_internal_frames_flag[] = hide_internal_frames
        end

        # Allow external code to edit information in the frames (e.g. line numbers with Revise)
        try invokelatest(update_stackframes_callback[], filtered) catch end

        if hide_internal_frames || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))
            show_compact_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks(), prefix)
        else
            # Find repeated cycles if trace is too long
            if length(filtered) > BIG_STACKTRACE_SIZE
                filtered, repeated_cycles, max_nested_cycles = _backtrace_find_and_remove_cycles(filtered)
            else
                repeated_cycles = NTuple{3, Int}[]
                max_nested_cycles = any(x -> last(x) > 1, filtered) ? 1 : 0
            end
            show_processed_backtrace(IOContext(io, :backtrace => true), filtered, nframes,
                repeated_cycles, max_nested_cycles;
                print_linebreaks = stacktrace_linebreaks(), prefix)
        end
        return
    end
else
    import Base:
        show_full_backtrace,
        show_reduced_backtrace

    function show_backtrace(io::IO, t::Vector)
        if haskey(io, :last_shown_line_infos)
            empty!(io[:last_shown_line_infos])
        end

        hide_internal_frames_flag = get(io, :compacttrace, nothing)
        if hide_internal_frames_flag isa RefValue{Bool}
            hide_internal_frames = hide_internal_frames_flag[]
            hide_internal_frames_flag[] = false # in case of early return
        else
            hide_internal_frames = false
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

        # restore
        if hide_internal_frames_flag isa RefValue{Bool}
            hide_internal_frames_flag[] = hide_internal_frames
        end

        if length(filtered) > BIG_STACKTRACE_SIZE
            show_reduced_backtrace(IOContext(io, :backtrace => true), filtered)
            return
        else
            try invokelatest(update_stackframes_callback[], filtered) catch end

            # process_backtrace returns a Vector{Tuple{Frame, Int}}
            if hide_internal_frames || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))
                show_compact_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
            else
                show_full_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
            end
        end
        return
    end

    # JULIA_STACKTRACE_MINIMAL only ever applies to abbreviated traces. On 1.13+ those are
    # rendered by `print_compact_stackframe`, so this override is only needed here.
    function print_stackframe(io, i, frame::StackFrame, n::Int, ndigits_max, modulecolor)
        file, line = string(frame.file), frame.line

        # Used by the REPL to make it possible to open
        # the location of a stackframe/method in the editor.
        if haskey(io, :last_shown_line_infos)
            push!(io[:last_shown_line_infos], (string(frame.file), frame.line))
        end

        inlined = getfield(frame, :inlined)
        modul = parentmodule(frame)

        digit_align_width = ndigits_max + 2

        # frame number
        print(io, " ", lpad("[" * string(i) * "]", digit_align_width))
        print(io, " ")

        hide_internal_frames_flag = get(io, :compacttrace, nothing)
        hide_internal_frames = hide_internal_frames_flag isa RefValue{Bool} ? hide_internal_frames_flag[] : false
        hide_internal_frames = (hide_internal_frames || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))) && parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))
        StackTraces.show_spec_linfo(IOContext(io, :backtrace=>true), frame, hide_internal_frames)
        if n > 1
            printstyled(io, " (repeats $n times)"; color=Base.warn_color(), bold=true)
        end

        # @ Module path / file : line
        if hide_internal_frames
            print_module_path_file(io, modul, file, line; modulecolor, digit_align_width = 1)
        else
            println(io)
            print_module_path_file(io, modul, file, line; modulecolor, digit_align_width)
        end

        # inlined
        printstyled(io, inlined ? " [inlined]" : "", color = :light_black)
    end
end

function show_exception_stack(io::IO, stack::ExceptionStack)
    # Display exception stack with the top of the stack first.  This ordering
    # means that the user doesn't have to scroll up in the REPL to discover the
    # root cause.
    nexc = length(stack)
    for i = nexc:-1:1
        if nexc != i
            printstyled(io, "\ncaused by: ", color=Base.error_color())
        end
        bt = stack[i].backtrace
        showerror(io, stack[i].exception, bt; backtrace = bt!==nothing)
        i == 1 || println(io)
    end
end

show(io::IO, stack::ExceptionStack) = show(io, MIME("text/plain"), stack)
function show(io::IO, ::MIME"text/plain", stack::ExceptionStack)
    nexc = length(stack)
    printstyled(io, nexc, "-element ExceptionStack", nexc == 0 ? "" : ":\n")
    show_exception_stack(io, stack)
end
