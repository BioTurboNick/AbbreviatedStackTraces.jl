module AbbreviatedStackTraces

include("override-client.jl")
include("override-errorshow.jl")
include("override-stacktraces.jl")

import Base:
    printstyled,
    RefValue,
    StackFrame,
    stacktrace_contract_userdir,
    stacktrace_expand_basepaths,
    STACKTRACE_FIXEDCOLORS,
    STACKTRACE_MODULECOLORS

import Base.StackTraces:
    is_top_level_frame,
    stacktrace

if isdefined(Main, :VSCodeServer)
    @eval (@__MODULE__) begin
        is_ide_support(path) = contains(path, r"[/\\].vscode[/\\]")
    end
    include("../ext/AbbrvStackTracesVSCodeServerExt.jl")
else
    # fallback
    @eval (@__MODULE__) begin
        is_ide_support(path) = false
    end
end

is_repl(path) = startswith(path, r"(.[/\\])?REPL")
is_julia_dev(path) = contains(path, r"[/\\].julia[/\\]dev[/\\]")
is_julia(path) =
    (startswith(path, r".[/\\]") && !is_repl(path)) ||
    (contains(path, r"[/\\].julia[/\\]") && !is_julia_dev(path)) ||
    contains(path, r"[/\\]julia[/\\]stdlib[/\\]")
is_broadcast(path) = startswith(path, r".[/\\]broadcast.jl")

# Process of identifying a visible frame:
# 1. Identify modules that should be included:
#     - Include: All modules observed in backtrace
#     - Exclude: Modules in Julia Base files, StdLibs, added packages, or registered by an IDE.
#     - Include: Modules in ENV["JULIA_DEBUG"]
#     - Exclude: Modules in ENV["JULIA_DEBUG"] that lead with `!`
# 2. Identify all frames in included modules
# 3. Include frames that have a file name matching ENV["JULIA_DEBUG"]
# 4. Exclude frames that have a file name matching ENV["JULIA_DEBUG"] that lead with `!`
# 5. This set of frames is considered user code.
# 6. Include the first frame above each contiguous set of user code frames to show what the user code called into.
# 7. To support broadcasting, identify any visible `materialize` frames, and include the first frame after
#    the broadcast functions, to show what function is being broadcast.
# 8. Optionally add back public frames based on ENV["JULIA_STACKTRACE_PUBLIC"]
# 9. Remove the topmost frame if it's a REPL toplevel.
# 10. Remove a broadcast materialize frame if it's the topmost frame.
function find_visible_frames(trace::Vector)
    public_frames_i = if parse(Bool, get(ENV, "JULIA_STACKTRACE_PUBLIC", "false"))
        pfi = findall(trace) do frame
            framemodule = parentmodule(frame[1])
            framemodule === nothing && return false
            module_public_names = names(framemodule)
            frame[1].func ∈ module_public_names
        end
        pfi !== nothing ? pfi : Int[]
    else
        Int[]
    end

    user_frames_i = let
        ufi = findall(trace) do frame
            file = String(frame[1].file)
            !is_julia(file) && !is_ide_support(file)
        end
        ufi !== nothing ? ufi : Int[]
    end

    # construct set of visible modules
    all_modules = convert(Vector{Module}, filter!(!isnothing, unique(t[1] |> parentmodule for t ∈ trace)))
    user_modules = convert(Vector{Module}, filter!(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[user_frames_i])))
    Main ∈ user_modules || push!(user_modules, Main)

    debug_entries = split(get(ENV, "JULIA_DEBUG", ""), ",")
    debug_include = filter(x -> !startswith(x, "!"), debug_entries)
    debug_exclude = lstrip.(filter!(x -> startswith(x, "!"), debug_entries), '!')

    debug_include_modules = filter(m -> string(m) ∈ debug_include, all_modules)
    debug_exclude_modules = filter(m -> string(m) ∈ debug_exclude, all_modules)
    setdiff!(union!(user_modules, debug_include_modules), debug_exclude_modules)

    # construct set of visible frames
    visible_frames_i = findall(trace) do frame
        file = String(frame[1].file)
        filenamebase = file |> basename |> splitext |> first
        mod = parentmodule(frame[1])
        return (mod ∈ user_modules || filenamebase ∈ debug_include) &&
            !(filenamebase ∈ debug_exclude) ||
            is_top_level_frame(frame[1]) && is_repl(file) ||
            !is_julia(file) && !is_ide_support(file)
    end

    # add one additional frame above each contiguous set of user code frames, removing 0.
    filter!(>(0), sort!(union!(visible_frames_i, visible_frames_i .- 1)))

    # remove Main frames that originate from internal code (e.g. BenchmarkTools)
    filter!(i -> parentmodule(trace[i][1]) != Main || !is_julia(string(trace[i][1].file)), visible_frames_i)

    # for each appearance of an already-visible `materialize` broadcast frame, include
    # the next immediate hidden frame after the last `broadcast` frame
    broadcasti = []
    for i ∈ visible_frames_i
        trace[i][1].func == :materialize || continue
        push!(broadcasti, findlast(trace[1:i - 1]) do frame
            !is_broadcast(String(frame[1].file))
        end)
    end
    sort!(union!(visible_frames_i, filter!(!isnothing, broadcasti)))

    # add back public frames
    sort!(union!(visible_frames_i, public_frames_i))

    if !isempty(visible_frames_i) && length(trace) > 1 && visible_frames_i[end] != length(trace)
        # add back the top level if it's not included (as can happen if a macro is expanded at top-level)
        push!(visible_frames_i, length(trace))
    end

    if length(visible_frames_i) > 0 && visible_frames_i[end] == length(trace)
        # remove REPL-based top-level
        # note: file field for top-level is different from the rest, doesn't include ./
        startswith(String(trace[end][1].file), "REPL") && pop!(visible_frames_i)
    end

    if length(visible_frames_i) == 1 && trace[only(visible_frames_i)][1].func == :materialize
        # remove a materialize frame if it is the only visible frame
        pop!(visible_frames_i)
    end

    return visible_frames_i
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
        modules = filter!(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[i:j]))
        print(io, " " ^ (ndigits_max + 4))
        printstyled(io, "⋮ ", bold = true)
        if VERSION ≥ v"1.10-alpha"
            printstyled(io, "internal", color = :light_black, italic=true)
        else
            printstyled(io, "internal", color = :light_black)
        end
        print(io, " ")
        if VERSION ≥ v"1.10-alpha"
            printstyled(io, "@ ", color = :light_black, italic=true)
        else
            printstyled(io, "@ ", color = :light_black)
        end
        if length(modules) > 0
            for (i, m) ∈ enumerate(modules)
                modulecolor = get_modulecolor!(modulecolordict, m, modulecolorcycler)
                if VERSION ≥ v"1.10-alpha"
                    printstyled(io, m, color = modulecolor, italic=true)
                    i < length(modules) && printstyled(io, ", ", color = :light_black, italic=true)
                else
                    printstyled(io, m, color = modulecolor)
                    i < length(modules) && printstyled(io, ", ", color = :light_black)
                end
                
            end
        end
        # indicate presence of inlined methods which lack module information
        # (they all do right now)
        if any(isnothing(parentmodule(t[1])) for t ∈ @view trace[i:j])
            if VERSION ≥ v"1.10-alpha"
                length(modules) > 0 && printstyled(io, ", ", color = :light_black, italic=true)
                printstyled(io, "Unknown", color = :light_black, italic=true)
            else
                length(modules) > 0 && printstyled(io, ", ", color = :light_black)
                printstyled(io, "Unknown", color = :light_black)
            end
        end
    end

    # select frames from user-controlled code and optionally public frames
    is = find_visible_frames(trace)
    
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
            Base.print_stackframe(io, i, trace[i][1], trace[i][2], ndigits_max, modulecolordict, modulecolorcycler)
            if i < num_frames - 1
                print_linebreaks && println(io)
            end
            lasti = i
        end

        # print if frames other than top-level were omitted
        hide_internal_frames_flag = get(io, :compacttrace, nothing)
        if num_frames - 1 > num_vis_frames
            if lasti < num_frames - 1
                println(io)
                print_omitted_modules(lasti + 1, num_frames - 1)
            end
            hide_internal_frames_flag isa RefValue{Bool} && (hide_internal_frames_flag[] = true)
        else
            hide_internal_frames_flag isa RefValue{Bool} && (hide_internal_frames_flag[] = false)
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

stacktrace(stack::Vector{StackFrame}) = stack

end
