module AbbreviatedStackTraces
__precompile__(false)

import Core:
    SimpleVector
import REPL:
    print_response
import Base:
    BIG_STACKTRACE_SIZE,
    CodeInfo,
    contractuser,
    demangle_function_name,
    display_error,
    empty_sym,
    fixup_stdlib_path,
    invokelatest,
    MethodInstance,
    printstyled,
    print_stackframe,
    print_within_stacktrace,
    process_backtrace,
    scrub_repl_backtrace,
    show,
    showerror,
    show_backtrace,
    show_datatype,
    show_exception_stack,
    show_full_backtrace,
    show_reduced_backtrace,
    show_tuple_as_call,
    show_type_name,
    StackFrame,
    stacktrace_contract_userdir,
    stacktrace_expand_basepaths,
    STACKTRACE_FIXEDCOLORS,
    STACKTRACE_MODULECOLORS,
    stacktrace_linebreaks,
    update_stackframes_callback

import Distributed:
    myid,
    RemoteException,
    showerror

import Base.StackTraces:
    is_top_level_frame,
    show_spec_linfo,
    stacktrace,
    top_level_scope_sym


if isdefined(Base, :ExceptionStack)
    oldversion = false
    import Base.ExceptionStack
else
    import Base:
        getindex,
        size
    oldversion = true
    struct ExceptionStack <: AbstractArray{Any,1}
        stack
    end
    function current_exceptions(task=current_task(); backtrace=true)
        raw = ccall(:jl_get_excstack, Any, (Any,Cint,Cint), task, backtrace, typemax(Cint))::Vector{Any}
        formatted = Any[]
        stride = backtrace ? 3 : 1
        for i = reverse(1:stride:length(raw))
            exc = raw[i]
            bt = backtrace ? Base._reformat_bt(raw[i+1],raw[i+2]) : nothing
            push!(formatted, (exception=exc,backtrace=bt))
        end
        ExceptionStack(formatted)
    end
    size(s::ExceptionStack) = size(s.stack)
    getindex(s::ExceptionStack, i::Int) = s.stack[i]
end

is_ide_support(path) = false # loaded early so it can be overwritten

include("vscode.jl")
VERSION < v"1.7-DEV" && include("pre17.jl")
if VERSION ≥ v"1.8.0-DEV.1040"
    # copied from REPL.jl with handling for display_error
    function print_response(errio::IO, response, show_value::Bool, have_color::Bool, specialdisplay::Union{AbstractDisplay,Nothing}=nothing)
        Base.sigatomic_begin()
        val, iserr = response
        while true
            try
                Base.sigatomic_end()
                if iserr
                    val = Base.scrub_repl_backtrace(val)
                    Base.istrivialerror(val) || ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, val)
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
            catch
                if iserr
                    println(errio) # an error during printing is likely to leave us mid-line
                    println(errio, "SYSTEM (REPL): showing an error caused an error")
                    try
                        excs = Base.scrub_repl_backtrace(current_exceptions())
                        ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, excs)
                        Base.invokelatest(Base.display_error, errio, excs, true)
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
    include("pre18dev1040.jl")
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

is_repl(path) = startswith(path, r".[/\\]REPL")
is_julia(path) = startswith(path, r".[/\\]") || contains(path, r"[/\\].julia[/\\]") || contains(path, r"[/\\]julia[/\\]stdlib[/\\]")
#is_ide_support(path) = false # replaced by IDE environment, defined above so the VSCode one is loaded after
is_dev_pkg(path) = contains(path, r"[/\\].julia[/\\]dev[/\\]")
is_broadcast(path) = startswith(path, r".[/\\]broadcast.jl")

function find_external_frames(trace::Vector)
    # select frames from user-controlled code
    # user-controlled code is:
    #    - Code on the REPL
    #    - Code outside ./, /.julia, or /julia, or a path provided by the IDE (e.g. /.vscode)
    #    - Code inside /.julia/dev
    is = findall(trace) do frame
        file = String(frame[1].file)
        is_repl(file) ||
        !is_julia(file) ||
        is_dev_pkg(file) ||
        is_ide_support(file) ||
        (is_top_level_frame(frame[1]) && startswith(file, "REPL"))
    end

    # get list of visible modules
    visible_modules = convert(Vector{Module}, filter!(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[is])))
    Main ∈ visible_modules || push!(visible_modules, Main)

    # find the highest contiguous internal frames evaluted in the context of a visible module
    internali = setdiff!(findall(trace) do frame
        parentmodule(frame[1]) ∈ visible_modules
    end, is)
    setdiff!(internali, internali .+ 1)

    # include the next immediate hidden frame called into from user-controlled code
    filter!(>(0), sort!(union!(is, union!(is .- 1, internali .- 1))))

    # for each appearance of an already-visible `materialize` broadcast frame, include
    # the next immediate hidden frame after the last `broadcast` frame
    broadcasti = []
    for i ∈ is
        trace[i][1].func == :materialize || continue
        push!(broadcasti, findlast(trace[1:i - 1]) do frame
            !is_broadcast(String(frame[1].file))
        end)
    end
    sort!(union!(is, filter!(!isnothing, broadcasti)))

    if length(is) > 0 && is[end] == length(trace)
        # remove REPL-based top-level
        # note: file field for top-level is different from the rest, doesn't include ./
        startswith(String(trace[end][1].file), "REPL") && pop!(is)
    end

    if length(is) == 1 && trace[only(is)][1].func == :materialize
        # remove a materialize frame if it is the only visible frame
        pop!(is)
    end

    return is
end

function show_compact_backtrace(io::IO, trace::Vector; print_linebreaks::Bool)
    #= Show the lowest stackframe and display a message telling user how to
    retrieve the full trace =#
    num_frames = length(trace)
    ndigits_max = ndigits(num_frames) * 2 + 1

    modulecolordict = copy(STACKTRACE_FIXEDCOLORS)
    modulecolorcycler = Iterators.Stateful(Iterators.cycle(STACKTRACE_MODULECOLORS))

    function print_omitted_modules(i, j)
        # Find modules involved in intermediate frames and print them
        modules = filter!(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[i:j]))
        if i < j
            print(io, " " ^ (ndigits_max - ndigits(i) - ndigits(j)))
            print(io, "[" * string(i) * "-" * string(j) * "] ")
        else
            print(io, " " ^ (ndigits_max - ndigits(i) + 1))
            print(io, "[" * string(i) * "] ")
        end
        printstyled(io, "⋮ ", bold = true)
        printstyled(io, "internal", color = :light_black)
        if !parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))
            println(io)
            print(io, " " ^ (ndigits_max + 2))
        else
            print(io, " ")
        end
        printstyled(io, "@ ", color = :light_black)
        if length(modules) > 0
            for (i, m) ∈ enumerate(modules)
                modulecolor = get_modulecolor!(modulecolordict, m, modulecolorcycler)
                printstyled(io, m, color = modulecolor)
                i < length(modules) && print(io, ", ")
            end
        end
        # indicate presence of inlined methods which lack module information
        # (they all do right now)
        if any(isnothing(parentmodule(t[1])) for t ∈ @view trace[i:j])
            length(modules) > 0 && print(io, ", ")
            printstyled(io, "Unknown", color = :light_black)
        end
    end

    # select frames from user-controlled code
    is = find_external_frames(trace)
    
    num_vis_frames = length(is)

    if num_vis_frames > 0
        print(io, "\nStacktrace:")

        if is[1] > 1
            println(io)
            print_omitted_modules(1, is[1] - 1)
        end

        lasti = first(is)
        @views for i ∈ is
            if i > lasti + 1
                println(io)
                print_omitted_modules(lasti + 1, i - 1)
            end
            println(io)
            print_stackframe(io, i, trace[i][1], trace[i][2], ndigits_max, modulecolordict, modulecolorcycler)
            if i < num_frames - 1
                print_linebreaks && println(io)
            end
            lasti = i
        end

        # print if frames other than top-level were omitted
        if num_frames - 1 > num_vis_frames 
            if lasti < num_frames - 1
                println(io)
                print_omitted_modules(lasti + 1, num_frames - 1)
            end
            println(io)
            print(io, "Use `err` to retrieve the full stack trace.")
        end
    end
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

# copied from Distributed/process_messages.jl and added dealing with RemoteException
function showerror(io::IO, re::RemoteException)
    (re.pid != myid()) && print(io, "On worker ", re.pid, ":\n")
    showerror(IOContext(io, :compacttrace => false), re.captured)
end

stacktrace(stack::Vector{StackFrame}) = stack

# copied from client.jl with added compacttrace argument, and scrubing error frame
function display_error(io::IO, stack::ExceptionStack, compacttrace::Bool = false)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    stack = ExceptionStack([ (exception = x.exception, backtrace = scrub_repl_backtrace(x.backtrace)) for x in stack ])
    istrivial = length(stack) == 1 && length(stack[1].backtrace) ≤ 1 # frame 1 = top level
    !istrivial && ccall(:jl_set_global, Cvoid, (Any, Any, Any), Main, :err, stack)
    show_exception_stack(IOContext(io, :limit => true, :compacttrace => isinteractive() ? compacttrace : false), stack)
    println(io)
end
display_error(stack::ExceptionStack, compacttrace = false) = display_error(stderr, stack, compacttrace)

# copied from errorshow.jl with added compacttrace argument
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
function show_backtrace(io::IO, t::Vector)
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
    if get(io, :compacttrace, false) || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))
        show_compact_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
    else
        show_full_backtrace(io, filtered; print_linebreaks = stacktrace_linebreaks())
    end
    return
end

# copied from client.jl with added code to account for sysimages that are missing `eval`
function scrub_repl_backtrace(bt)
    if bt !== nothing && !(bt isa Vector{Any}) # ignore our sentinel value types
        bt = stacktrace(bt)
        # remove REPL-related frames from interactive printing
        eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval, bt)
        # sysimages may drop debug info and won't have inlined frames present in the backtrace
        # in that case, `eval` may be dropped, but `eval_user_input` should be present
        eval_ind === nothing && (eval_ind = findlast(frame -> !frame.from_c && frame.func === :eval_user_input, bt))
        eval_ind === nothing || deleteat!(bt, eval_ind:length(bt))
    end
    return bt
end

function print_stackframe(io, i, frame::StackFrame, n::Int, digit_align_width, modulecolor)
    file, line = string(frame.file), frame.line
    file = fixup_stdlib_path(file)
    stacktrace_expand_basepaths() && (file = something(find_source_file(file), file))
    stacktrace_contract_userdir() && (file = contractuser(file))

    # Used by the REPL to make it possible to open
    # the location of a stackframe/method in the editor.
    if haskey(io, :last_shown_line_infos)
        push!(io[:last_shown_line_infos], (string(frame.file), frame.line))
    end

    inlined = getfield(frame, :inlined)
    modul = parentmodule(frame)

    # frame number
    print(io, " ", lpad("[" * string(i) * "]", digit_align_width + 2))
    print(io, " ")

    StackTraces.show_spec_linfo(IOContext(io, :backtrace=>true), frame)
    if n > 1
        printstyled(io, " (repeats $n times)"; color=:light_black)
    end

    if !(get(io, :compacttrace, false) && parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))) #get(io, :minimaltrace, false))
        println(io)
        print(io, " " ^ (digit_align_width + 1))
    end

    # @
    printstyled(io, " " * "@ ", color = :light_black)

    # module
    if modul !== nothing
        printstyled(io, modul, color = modulecolor)
        print(io, " ")
    end

    # filepath
    pathparts = splitpath(file)
    folderparts = pathparts[1:end-1]
    if !isempty(folderparts)
        printstyled(io, joinpath(folderparts...) * (Sys.iswindows() ? "\\" : "/"), color = :light_black)
    end

    # filename, separator, line
    # use escape codes for formatting, printstyled can't do underlined and color
    # codes are bright black (90) and underlined (4)
    if VERSION ≥ v"1.7-DEV"
        printstyled(io, pathparts[end], ":", line; color = :light_black, underline = true)
    else
        printstyled(io, pathparts[end], ":", line; color = :light_black)
    end

    # inlined
    printstyled(io, inlined ? " [inlined]" : "", color = :light_black)
end

#copied from stacktraces.jl to add compact option
function show_spec_linfo(io::IO, frame::StackFrame)
    linfo = frame.linfo
    if linfo === nothing || (get(io, :compacttrace, false) && parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))) #get(io, :minimaltrace, false))
        if frame.func === empty_sym
            print(io, "ip:0x", string(frame.pointer, base=16))
        elseif frame.func === top_level_scope_sym
            print(io, "top-level scope")
        else
            Base.print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
        end
    elseif linfo isa MethodInstance
        def = linfo.def
        if isa(def, Method)
            sig = linfo.specTypes
            if isnothing(sig) # inlined, which is currently lacking the other information
                Base.print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
            else
                argnames = Base.method_argnames(def)
                if def.nkw > 0
                    # rearrange call kw_impl(kw_args..., func, pos_args...) to func(pos_args...)
                    kwarg_types = Any[ fieldtype(sig, i) for i = 2:(1+def.nkw) ]
                    uw = Base.unwrap_unionall(sig)::DataType
                    pos_sig = Base.rewrap_unionall(Tuple{uw.parameters[(def.nkw+2):end]...}, sig)
                    kwnames = argnames[2:(def.nkw+1)]
                    for i = 1:length(kwnames)
                        str = string(kwnames[i])::String
                        if endswith(str, "...")
                            kwnames[i] = Symbol(str[1:end-3])
                        end
                    end
                    Base.show_tuple_as_call(io, def.name, pos_sig;
                                            demangle=true,
                                            kwargs=zip(kwnames, kwarg_types),
                                            argnames=argnames[def.nkw+2:end])
                else
                    Base.invokelatest(show_tuple_as_call, io, def.name, sig; demangle=true, argnames)
                end
            end
        else
            Base.show_mi(io, linfo, true)
        end
    elseif linfo isa CodeInfo
        print(io, "top-level scope")
    end
end

function show_datatype(io::IO, @nospecialize(x::DataType))
    parameters = x.parameters::SimpleVector
    istuple = x.name === Tuple.name
    n = length(parameters)

    # Print homogeneous tuples with more than 3 elements compactly as NTuple{N, T}
    if istuple && n > 3 && all(i -> (parameters[1] === i), parameters)
        print(io, "NTuple{", n, ", ", parameters[1], "}")
    else
        show_type_name(io, x.name)
        if (n > 0 || istuple) && x !== Tuple
            # Do not print the type parameters for the primary type if we are
            # printing a method signature or type parameter.
            # Always print the type parameter if we are printing the type directly
            # since this information is still useful.
            print(io, '{')
            omitted = get(io, :compacttrace, false) && n > 2
            omitted && (n = 2)
            for i = 1:n
                p = parameters[i]
                show(io, p)
                i < n && print(io, ", ")
            end
            omitted && print(io, ", …")
            print(io, '}')
        end
    end
end

end
