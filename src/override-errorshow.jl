__precompile__(false)

import Base:
    BIG_STACKTRACE_SIZE,
    contractuser,
    fixup_stdlib_path,
    invokelatest,
    printstyled,
    print_module_path_file,
    print_stackframe,
    process_backtrace,
    show,
    show_backtrace,
    show_exception_stack,
    show_full_backtrace,
    show_reduced_backtrace,
    showerror,
    StackFrame,
    stacktrace_contract_userdir,
    stacktrace_expand_basepaths,
    stacktrace_linebreaks,
    update_stackframes_callback,
    StackTraces

function show_backtrace(io::IO, t::Vector)
    if haskey(io, :last_shown_line_infos)
        empty!(io[:last_shown_line_infos])
    end

    # this will be set to true if types in the stacktrace are truncated
    limitflag = Ref(false)
    io = IOContext(io, :stacktrace_types_limited => limitflag)

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
    else
        try invokelatest(update_stackframes_callback[], filtered) catch end
        # process_backtrace returns a Vector{Tuple{Frame, Int}}
        if get(io, :compacttrace, false) || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))
            show_compact_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
        else
            show_full_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
        end
    end

    if limitflag[]
        print(io, "\nSome type information was truncated. Use `show(err)` to see complete types.")
    end
    return
end

if VERSION < v"1.10-alpha1"
    import Base:
        _simplify_include_frames

    # Copied from v1.10-alpha1
    # Collapse frames that have the same location (in some cases)
    function _collapse_repeated_frames(trace)
        kept_frames = trues(length(trace))
        last_frame = nothing
        for i in 1:length(trace)
            frame::StackFrame, _ = trace[i]
            if last_frame !== nothing && frame.file == last_frame.file && frame.line == last_frame.line
                #=
                Handles this case:

                f(g, a; kw...) = error();
                @inline f(a; kw...) = f(identity, a; kw...);
                f(1)

                which otherwise ends up as:

                [4] #f#4 <-- useless
                @ ./REPL[2]:1 [inlined]
                [5] f(a::Int64)
                @ Main ./REPL[2]:1
                =#
                if startswith(sprint(show, last_frame), "#")
                    kept_frames[i-1] = false
                end

                #= Handles this case
                g(x, y=1, z=2) = error();
                g(1)

                which otherwise ends up as:

                [2] g(x::Int64, y::Int64, z::Int64)
                @ Main ./REPL[1]:1
                [3] g(x::Int64) <-- useless
                @ Main ./REPL[1]:1
                =#
                if frame.linfo isa MethodInstance && last_frame.linfo isa MethodInstance &&
                    frame.linfo.def isa Method && last_frame.linfo.def isa Method
                    m, last_m = frame.linfo.def::Method, last_frame.linfo.def::Method
                    params, last_params = Base.unwrap_unionall(m.sig).parameters, Base.unwrap_unionall(last_m.sig).parameters
                    if last_m.nkw != 0
                        pos_sig_params = last_params[(last_m.nkw+2):end]
                        issame = true
                        if pos_sig_params == params
                            kept_frames[i] = false
                        end
                    end
                    if length(last_params) > length(params)
                        issame = true
                        for i = 1:length(params)
                            issame &= params[i] == last_params[i]
                        end
                        if issame
                            kept_frames[i] = false
                        end
                    end
                end

                # TODO: Detect more cases that can be collapsed
            end
            last_frame = frame
        end
        return trace[kept_frames]
    end
    
    if VERSION < v"1.9"
        # copied just to add access to _collapse_repeated_frames, without kwcall
        function process_backtrace(t::Vector, limit::Int=typemax(Int); skipC = true)
            n = 0
            last_frame = StackTraces.UNKNOWN
            count = 0
            ret = Any[]
            for i in eachindex(t)
                lkups = t[i]
                if lkups isa StackFrame
                    lkups = [lkups]
                else
                    lkups = StackTraces.lookup(lkups)
                end
                for lkup in lkups
                    if lkup === StackTraces.UNKNOWN
                        continue
                    end

                    if (lkup.from_c && skipC)
                        continue
                    end
                    code = lkup.linfo
                    if code isa MethodInstance
                        def = code.def
                        if def isa Method && def.sig <: Tuple{NamedTuple,Any,Vararg}
                            # hide keyword methods, which are probably internal keyword sorter methods
                            # (we print the internal method instead, after demangling
                            # the argument list, since it has the right line number info)
                            continue
                        end
                    end
                    count += 1
                    if count > limit
                        break
                    end

                    if lkup.file != last_frame.file || lkup.line != last_frame.line || lkup.func != last_frame.func || lkup.linfo !== last_frame.linfo
                        if n > 0
                            push!(ret, (last_frame, n))
                        end
                        n = 1
                        last_frame = lkup
                    else
                        n += 1
                    end
                end
                count > limit && break
            end
            if n > 0
                push!(ret, (last_frame, n))
            end
            trace = _simplify_include_frames(ret)
            trace = _collapse_repeated_frames(trace)
            return trace
        end
    else
        # copied just to add access to _collapse_repeated_frames
        function process_backtrace(t::Vector, limit::Int=typemax(Int); skipC = true)
            n = 0
            last_frame = StackTraces.UNKNOWN
            count = 0
            ret = Any[]
            for i in eachindex(t)
                lkups = t[i]
                if lkups isa StackFrame
                    lkups = [lkups]
                else
                    lkups = StackTraces.lookup(lkups)
                end
                for lkup in lkups
                    if lkup === StackTraces.UNKNOWN
                        continue
                    end

                    if (lkup.from_c && skipC)
                        continue
                    end
                    code = lkup.linfo
                    if code isa MethodInstance
                        def = code.def
                        if def isa Method && def.name !== :kwcall && def.sig <: Tuple{typeof(Core.kwcall),NamedTuple,Any,Vararg}
                            # hide kwcall() methods, which are probably internal keyword sorter methods
                            # (we print the internal method instead, after demangling
                            # the argument list, since it has the right line number info)
                            continue
                        end
                    elseif !lkup.from_c
                        lkup.func === :kwcall && continue
                    end
                    count += 1
                    if count > limit
                        break
                    end

                    if lkup.file != last_frame.file || lkup.line != last_frame.line || lkup.func != last_frame.func || lkup.linfo !== last_frame.linfo
                        if n > 0
                            push!(ret, (last_frame, n))
                        end
                        n = 1
                        last_frame = lkup
                    else
                        n += 1
                    end
                end
                count > limit && break
            end
            if n > 0
                push!(ret, (last_frame, n))
            end
            trace = _simplify_include_frames(ret)
            trace = _collapse_repeated_frames(trace)
            return trace
        end
    end
end

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

    minimal = (get(io, :compacttrace, false) || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))) && parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))
    StackTraces.show_spec_linfo(IOContext(io, :backtrace=>true), frame, minimal)
    if n > 1
        printstyled(io, " (repeats $n times)"; color=:light_black)
    end

    # @ Module path / file : line
    if minimal
        print_module_path_file(io, modul, file, line; modulecolor, digit_align_width = 1)
    else
        println(io)
        print_module_path_file(io, modul, file, line; modulecolor, digit_align_width)
    end

    # inlined
    printstyled(io, inlined ? " [inlined]" : "", color = :light_black)
end

if VERSION < v"1.9"
    function print_module_path_file(io, modul, file, line; modulecolor = :light_black, digit_align_width = 0)
        printstyled(io, " " ^ digit_align_width * "@", color = :light_black)
    
        # module
        if modul !== nothing && modulecolor !== nothing
            print(io, " ")
            printstyled(io, modul, color = modulecolor)
        end
    
        # filepath
        file = fixup_stdlib_path(file)
        stacktrace_expand_basepaths() && (file = something(find_source_file(file), file))
        stacktrace_contract_userdir() && (file = contractuser(file))
        print(io, " ")
        dir = dirname(file)
        !isempty(dir) && printstyled(io, dir, Filesystem.path_separator, color = :light_black)
    
        # filename, separator, line
        printstyled(io, basename(file), ":", line; color = :light_black, underline = true)
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

show(io::IO, stack::ExceptionStack; kwargs...) = show(io, MIME("text/plain"), stack; kwargs...)
function show(io::IO, ::MIME"text/plain", stack::ExceptionStack; show_repl_frames = false)
    nexc = length(stack)
    printstyled(io, nexc, "-element ExceptionStack", nexc == 0 ? "" : ":\n")
    if !show_repl_frames
        stack = ExceptionStack([ (exception = x.exception, backtrace = x.backtrace) for x in stack ])
    end
    show_exception_stack(io, stack)
end
