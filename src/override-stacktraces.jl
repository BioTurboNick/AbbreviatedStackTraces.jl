__precompile__(false)

import Base:
    CodeInfo,
    empty_sym,
    StackFrame,
    MethodInstance,
    show_tuple_as_call

import Base.StackTraces:
    lookup,
    show_spec_linfo,
    show_spec_sig,
    top_level_scope_sym

function show_spec_linfo(io::IO, frame::StackFrame, minimal = false)
    linfo = frame.linfo
    if linfo === nothing || minimal
        if frame.func === empty_sym
            print(io, "ip:0x", string(frame.pointer, base=16))
        elseif frame.func === top_level_scope_sym
            print(io, "top-level scope")
        else
            Base.print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
        end
    elseif linfo isa CodeInfo
        print(io, "top-level scope")
    elseif linfo isa Module
        Base.print_within_stacktrace(io, Base.demangle_function_name(string(frame.func)), bold=true)
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
