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

if VERSION ≤ v"1.11"
    function show_spec_linfo(io::IO, frame::StackFrame, minimal::Bool = false)
        linfo = frame.linfo
        if linfo === nothing || minimal
            if frame.func === empty_sym
                print(io, "ip:0x", string(frame.pointer, base=16))
            elseif frame.func === top_level_scope_sym
                print(io, "top-level scope")
            else
                print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
            end
        elseif linfo isa CodeInfo
            print(io, "top-level scope")
        elseif linfo isa Module
            print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
        elseif linfo isa MethodInstance
            def = linfo.def
            if def isa Module
                show_mi(io, linfo, #=from_stackframe=#true)
            else
                show_spec_sig(io, def, linfo.specTypes)
            end
        else
            m = linfo::Method
            show_spec_sig(io, m, m.sig)
        end
    end
else
    import Base.StackTraces:
        frame_method_or_module,
        frame_mi

    function show_spec_linfo(io::IO, frame::StackFrame, minimal::Bool = false)
        linfo = frame.linfo
        if linfo === nothing || minimal
            if frame.func === empty_sym
                print(io, "ip:0x", string(frame.pointer, base=16))
            elseif frame.func === top_level_scope_sym
                print(io, "top-level scope")
            else
                print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
            end
        elseif linfo isa CodeInfo
            print(io, "top-level scope")
        elseif linfo isa Module
            print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
        else
            if linfo isa Union{MethodInstance, CodeInstance}
                def = frame_method_or_module(frame)
                if def isa Module
                    show_mi(io, linfo, #=from_stackframe=#true)
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
