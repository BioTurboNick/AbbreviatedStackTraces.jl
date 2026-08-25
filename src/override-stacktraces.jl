import Base:
    CodeInfo,
    CodeInstance,
    empty_sym,
    MethodInstance,
    print_within_stacktrace,
    show_tuple_as_call,
    StackFrame

import Base.StackTraces:
    show_spec_linfo,
    show_spec_sig,
    top_level_scope_sym

#= `JULIA_STACKTRACE_MINIMAL` drops the specialization signature of a frame and prints just
the function name. Only abbreviated traces honor it, so from 1.13 on this is a helper called
from `print_compact_stackframe` rather than an override of `show_spec_linfo`, which lets
Base keep full control of ordinary trace rendering. =#
function show_spec_linfo_minimal(io::IO, frame::StackFrame)
    if frame.func === empty_sym
        print(io, "ip:0x", string(frame.pointer, base=16))
    elseif frame.func === top_level_scope_sym
        print(io, "top-level scope")
    else
        print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
    end
end

if VERSION ≤ v"1.12-alpha"
    function show_spec_linfo(io::IO, frame::StackFrame, minimal::Bool = false)
        linfo = frame.linfo
        if linfo === nothing || minimal
            show_spec_linfo_minimal(io, frame)
        elseif linfo isa CodeInfo
            print(io, "top-level scope")
        elseif linfo isa Module
            print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
        elseif linfo isa MethodInstance
            def = linfo.def
            if def isa Module
                Base.show_mi(io, linfo, #=from_stackframe=#true)
            else
                show_spec_sig(io, def, linfo.specTypes)
            end
        else
            m = linfo::Method
            show_spec_sig(io, m, m.sig)
        end
    end
elseif VERSION < v"1.13.0-rc3"
    import Base.StackTraces:
        frame_method_or_module,
        frame_mi

    function show_spec_linfo(io::IO, frame::StackFrame, minimal::Bool = false)
        linfo = frame.linfo
        if linfo === nothing || minimal
            show_spec_linfo_minimal(io, frame)
        elseif linfo isa CodeInfo
            print(io, "top-level scope")
        elseif linfo isa Module
            print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
        else
            if linfo isa Union{MethodInstance, CodeInstance}
                def = frame_method_or_module(frame)
                if def isa Module
                    Base.show_mi(io, linfo, #=from_stackframe=#true)
                else
                    show_spec_sig(io, def, frame_mi(frame).specTypes)
                end
            else
                m = linfo::Method
                show_spec_sig(io, m, m.sig)
            end
        end
    end
end
