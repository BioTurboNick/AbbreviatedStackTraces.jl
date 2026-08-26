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

if isassigned(Base.REPL_MODULE_REF) && nameof(Base.REPL_MODULE_REF[]) == :REPL
    include("../ext/AbbrvStackTracesREPLExt.jl")
end

#= 1.13 replaced the inline `(repeats n times)` annotation with cycle brackets drawn in a
gutter to the left of the frame numbers. =#
const HAS_CYCLE_BRACKETS = VERSION ≥ v"1.13.0-rc3"

is_repl(path) = startswith(path, r"(.[/\\])?REPL")
is_julia_dev(path) = contains(path, r"[/\\].julia[/\\]dev[/\\]")
#= Frames from Base and Core name a file relative to Julia's own source tree instead of an
absolute path: a bare file name from 1.14 on, and a `./`-prefixed one before that. The REPL's
pseudo-files (`REPL[1]`) are shaped the same way but are user code; they carry no extension.
Everything a user could write is absolutized by `include`, even from a relative path. =#
is_base_relative(path) =
    contains(path, r"[/\\]") ? startswith(path, r".[/\\]") : endswith(path, ".jl")
is_julia(path) =
    (is_base_relative(path) && !is_repl(path)) ||
    (contains(path, r"[/\\].julia[/\\]") && !is_julia_dev(path)) ||
    contains(path, r"[/\\]julia[/\\]stdlib[/\\]")
is_broadcast(path) = is_base_relative(path) && contains(path, r"(^|[/\\])broadcast\.jl$")

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
        #= Remove REPL-based top-level. Frames for functions defined at the prompt name the
        same pseudo-file as the top-level frame does — before 1.14 only the top-level one
        lacked a `./` prefix, so being top-level has to be checked outright, or a user's own
        function gets dropped whenever it is the last frame in the trace. =#
        frame = trace[end][1]
        is_top_level_frame(frame) && is_repl(String(frame.file)) && pop!(visible_frames_i)
    end

    return visible_frames_i
end

function show_compact_backtrace(io::IO, trace::Vector; print_linebreaks::Bool, prefix = nothing,
                                total_frames::Int = length(trace),
                                repeated_cycles::Vector{NTuple{3, Int}} = NTuple{3, Int}[],
                                max_nested_cycles::Int = 0)
    #= Show the lowest stackframe and display a message telling user how to
    retrieve the full trace =#
    num_frames = length(trace)

    # select frames from user-controlled code and optionally public frames
    is = find_visible_frames(trace)

    shown = Set(is)
    num_vis_frames = length(is)

    #= A cycle is bracketed around the frames of it that survive abbreviation: internal frames
    inside one are dropped like any other, and the `⋮` standing in for them carries the bracket
    across. So a cycle opens on the first frame of its span still being shown, and closes on the
    last — or, when its span runs on into frames that were dropped, on the `⋮` those become, so
    that the summary of a cycle's own frames is not left sitting outside it. A cycle with nothing
    left of it at all is not drawn. `span` stays the whole thing either way, because the frames a
    cycle stands for are counted over all of it.

    Base records a cycle's start and length against the frames it had collapsed so far, which
    can reach past either end of the trace it hands back, so the span is clamped to it. =#
    cycles = @NamedTuple{span::UnitRange{Int}, opens::Int, opens_at_gap::Bool,
                         closes::Int, closes_at_gap::Bool, reps::Int}[]
    for (start, len, reps) ∈ repeated_cycles
        span = max(firstindex(trace), start):min(lastindex(trace), start + len - 1)
        drawn = filter(∈(shown), span)
        # Nothing of it survives, so there is nothing to bracket
        isempty(drawn) && continue
        push!(cycles, (; span,
            opens = first(drawn), opens_at_gap = first(span) < first(drawn),
            closes = last(drawn), closes_at_gap = last(span) > last(drawn), reps))
    end
    repeats_shown = any(i -> trace[i][2] > 1, is)

    #= How many frames one turn round each cycle stands for, the repetitions of any cycle nested
    inside it included. Measured innermost-first so a cycle is already measured by the time the
    one enclosing it needs it, and the first cycle to enclose one claims it, which is the one it
    is immediately inside. =#
    spanned = zeros(Int, length(cycles))
    claimed = falses(length(cycles))
    order = sortperm(cycles, by = c -> length(c.span))
    for (pos, k) ∈ enumerate(order)
        spanned[k] = sum(j -> trace[j][2], cycles[k].span; init = 0)
        for m ∈ @view order[1:(pos - 1)]
            (!claimed[m] && cycles[m].span ⊆ cycles[k].span) || continue
            claimed[m] = true
            spanned[k] += (cycles[m].reps - 1) * spanned[m]
        end
    end

    #= Frame numbers are right-aligned to the width of the trace's whole frame count, repeats
    included, the way Base aligns its own — `total_frames` is that count, which is why it comes
    in rather than being `length(trace)` from 1.13 on. Cycle brackets are drawn in a gutter to
    the left of the numbers, as many columns as Base nested them deep, and the `⋮` markers move
    over with them. =#
    ndigits_max = ndigits(total_frames)
    drawing_cycles = HAS_CYCLE_BRACKETS && (!isempty(cycles) || repeats_shown)
    gutter = drawing_cycles ? max(max_nested_cycles, 1) : 0

    modulecolordict = copy(STACKTRACE_FIXEDCOLORS)
    modulecolorcycler = Iterators.Stateful(Iterators.cycle(STACKTRACE_MODULECOLORS))

    #= `depth` is how many cycles are open across the omitted frames, and `starts` how many begin
    on them. Their brackets carry on down the gutter past the `⋮`, which still lands in the
    column it would without them. =#
    function print_omitted_modules(i, j, depth = 0, starts = 0)
        # Find modules involved in intermediate frames and print them
        modules = filter!(!isnothing, unique(t[1] |> parentmodule for t ∈ @view trace[i:j]))
        prefix === nothing || print(io, prefix)
        print(io, " ")
        printstyled(io, "│" ^ depth, color = :light_black)
        printstyled(io, "┌" ^ starts, color = :light_black)
        print(io, " " ^ (ndigits_max + 3 + gutter - depth - starts))
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

    if num_vis_frames > 0
        println(io)
        prefix === nothing || print(io, prefix)
        print(io, "Stacktrace:")

        #= Walk the whole trace, not just the frames shown: Base numbers a frame by how many
        frames come before it with every repetition counted, so the hidden ones and the turns a
        closed cycle stands for both have to be counted past. A cycle's repetitions only start
        counting once it has closed, which is what numbers the frames it brackets as the first
        turn round it. =#
        open_cycles = @NamedTuple{closes::Int, closes_at_gap::Bool, span_end::Int, reps::Int}[]

        #= Close innermost-first, one at a time. Base's closing printer would otherwise adjust
        the cycles still open by spans it measured against the trace it collapsed, and these are
        measured against the frames actually drawn. `at_gap` distinguishes a cycle that ends on a
        frame from one that ends among the frames a `⋮` stands for. =#
        function close_cycles_ending!(at, at_gap, upto = typemax(Int))
            while !isempty(open_cycles) && open_cycles[end].closes == at &&
                    open_cycles[end].closes_at_gap == at_gap &&
                    open_cycles[end].span_end ≤ upto
                depth = length(open_cycles)
                reps = pop!(open_cycles).reps
                # Base's printer takes a start and a length, and counts frames itself
                close_cycles!(io, at, NTuple{4, Int}[(at, 1, reps, 0)], 0,
                    gutter, depth, ndigits_max; prefix)
            end
        end

        opening(k, at) = drawing_cycles && cycles[k].opens_at_gap && cycles[k].opens == at
        closing(k, at) = drawing_cycles && cycles[k].closes_at_gap && cycles[k].closes == at

        #= A gap can straddle a cycle boundary, standing in for frames on both sides of it. Split
        it there, so the frames belonging to the cycle get a `⋮` inside the bracket and those
        outside it get one of their own. =#
        function print_gap!(from, to, before)
            bounds = Int[]
            for k ∈ eachindex(cycles)
                opening(k, before) && first(cycles[k].span) > from &&
                    push!(bounds, first(cycles[k].span))
                closing(k, lasti) && last(cycles[k].span) < to &&
                    push!(bounds, last(cycles[k].span) + 1)
            end
            sort!(unique!(bounds))

            start = from
            for stop ∈ push!(bounds .- 1, to)
                starts = 0
                for k ∈ eachindex(cycles)
                    (opening(k, before) && first(cycles[k].span) == start) || continue
                    push!(open_cycles, (; cycles[k].closes, cycles[k].closes_at_gap,
                        span_end = last(cycles[k].span), cycles[k].reps))
                    starts += 1
                end
                println(io)
                print_omitted_modules(start, stop, length(open_cycles) - starts, starts)
                close_cycles_ending!(lasti, true, stop)
                start = stop + 1
            end
        end

        preceding = 0
        lasti = 0 # so that frames dropped before the first one shown are a gap like any other
        for i ∈ eachindex(trace)
            n = trace[i][2]
            if i ∈ shown
                i > lasti + 1 && print_gap!(lasti + 1, i - 1, i)

                ncycle_starts = 0
                if drawing_cycles
                    for k ∈ eachindex(cycles)
                        (cycles[k].opens == i && !cycles[k].opens_at_gap) || continue
                        push!(open_cycles, (; cycles[k].closes, cycles[k].closes_at_gap,
                            span_end = last(cycles[k].span), cycles[k].reps))
                        ncycle_starts += 1
                    end
                    # A frame repeated on its own opens and closes a cycle of one
                    if n > 1
                        push!(open_cycles, (; closes = i, closes_at_gap = false, span_end = i, reps = n))
                        ncycle_starts += 1
                    end
                end

                println(io)
                print_compact_stackframe(io, frame_number(1 + preceding, i), trace[i][1], n,
                    ndigits_max, gutter, length(open_cycles), ncycle_starts,
                    modulecolordict, modulecolorcycler; prefix)
                close_cycles_ending!(i, false)
                lasti = i
            end

            preceding += n
            # Once past a cycle, the turns it stands for count towards what follows
            for k ∈ eachindex(cycles)
                last(cycles[k].span) == i && (preceding += (cycles[k].reps - 1) * spanned[k])
            end
            if i ∈ shown && i < num_frames - 1
                print_linebreaks && println(io)
            end
        end

        # print if frames other than top-level were omitted
        hide_internal_frames_flag = get(io, :compacttrace, nothing)
        if num_frames - 1 > num_vis_frames
            if lasti < num_frames - 1
                println(io)
                print_omitted_modules(lasti + 1, num_frames - 1, length(open_cycles))
            end
            close_cycles_ending!(lasti, true)
            hide_internal_frames_flag isa RefValue{Bool} && (hide_internal_frames_flag[] = true)
        else
            hide_internal_frames_flag isa RefValue{Bool} && (hide_internal_frames_flag[] = false)
        end

        #= A cycle whose span ran into frames that were dropped without even a `⋮` to stand for
        them — the trace ended in them — would otherwise be left open. =#
        while !isempty(open_cycles)
            depth = length(open_cycles)
            reps = pop!(open_cycles).reps
            close_cycles!(io, lasti, NTuple{4, Int}[(lasti, 1, reps, 0)], 0,
                gutter, depth, ndigits_max; prefix)
        end
    else
        # No frame was selected as visible, which happens when every frame is internal
        # (This should be rare.)
        last_omitted = num_frames > 1 &&
            is_top_level_frame(trace[end][1]) &&
            is_repl(String(trace[end][1].file)) ? num_frames - 1 : num_frames
        if last_omitted ≥ 1
            println(io)
            prefix === nothing || print(io, prefix)
            print(io, "Stacktrace:")
            println(io)
            print_omitted_modules(1, last_omitted)
            hide_internal_frames_flag = get(io, :compacttrace, nothing)
            hide_internal_frames_flag isa RefValue{Bool} && (hide_internal_frames_flag[] = true)
        end
    end
end

minimal_frames() = parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))

@static if HAS_CYCLE_BRACKETS
    #= From 1.13 on, Base draws both the frame and a cycle's closing line, so the gutter and the
    frame-number column stay Base's arithmetic rather than a copy of it, and it numbers a frame
    by how many frames precede it rather than by its position in the collapsed trace. =#
    frame_number(frame_counter, i) = frame_counter

    function print_compact_stackframe(io, i, frame::StackFrame, n::Int, ndigits_max, gutter, nactive_cycles, ncycle_starts, modulecolordict, modulecolorcycler; prefix = nothing)
        if minimal_frames()
            print_minimal_stackframe(io, i, frame, ndigits_max, gutter, nactive_cycles,
                ncycle_starts, modulecolordict, modulecolorcycler; prefix)
        else
            Base.print_stackframe(io, i, frame, ndigits_max, gutter, nactive_cycles,
                ncycle_starts, modulecolordict, modulecolorcycler; prefix)
        end
    end

    close_cycles!(io, i, open_cycles, frame_counter, gutter, nactive_cycles, ndigits_max; prefix = nothing) =
        Base._backtrace_print_repetition_closings!(io, i, open_cycles, frame_counter, gutter,
            nactive_cycles, ndigits_max; prefix)

    #= `JULIA_STACKTRACE_MINIMAL` folds the location onto the frame's own line, which Base has
    no printer for; the gutter and the frame-number column are still Base's. =#
    function print_minimal_stackframe(io, i, frame::StackFrame, ndigits_max, gutter, nactive_cycles, ncycle_starts, modulecolordict, modulecolorcycler; prefix = nothing)
        # Used by the REPL to make it possible to open
        # the location of a stackframe/method in the editor.
        if haskey(io, :last_shown_line_infos)
            push!(io[:last_shown_line_infos], (string(frame.file), frame.line))
        end

        modul = parentmodule(frame)
        modulecolor = get_modulecolor!(modulecolordict, modul, modulecolorcycler)

        prefix === nothing || print(io, prefix)
        print(io, " ")
        printstyled(io, "├" ^ (nactive_cycles - ncycle_starts), color = :light_black)
        printstyled(io, "┌" ^ ncycle_starts, color = :light_black)
        print(io, lpad("[" * string(i) * "]", ndigits_max + 2 + gutter - nactive_cycles), " ")
        show_spec_linfo_minimal(IOContext(io, :backtrace => true), frame)
        print_module_path_file(io, modul, string(frame.file), frame.line;
            modulecolor, digit_align_width = 1)
        printstyled(io, getfield(frame, :inlined) ? " [inlined]" : "", color = :light_black)
    end
else
    #= Before 1.13, Base annotated a repeated frame inline as `(repeats n times)`, reserved no
    gutter, had no multi-frame cycles to draw, and numbered a frame by its position in the
    collapsed trace. `Base.print_stackframe` does all that, and the override in
    `override-errorshow.jl` handles `JULIA_STACKTRACE_MINIMAL`; abbreviated traces never carry a
    prefix before 1.13 either. =#
    frame_number(frame_counter, i) = i

    print_compact_stackframe(io, i, frame::StackFrame, n::Int, ndigits_max, gutter, nactive_cycles, ncycle_starts, modulecolordict, modulecolorcycler; prefix = nothing) =
        Base.print_stackframe(io, i, frame, n, ndigits_max, modulecolordict, modulecolorcycler)

    close_cycles!(io, i, open_cycles, frame_counter, gutter, nactive_cycles, ndigits_max; prefix = nothing) =
        (frame_counter, nactive_cycles)
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
