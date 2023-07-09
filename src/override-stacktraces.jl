__precompile__(false)

import Base:
    CodeInfo,
    empty_sym,
    StackFrame,
    MethodInstance,
    show_tuple_as_call

import Base.StackTraces:
    show_spec_linfo,
    top_level_scope_sym

if VERSION < v"1.10-alpha1"
    function show_spec_linfo(io::IO, frame::StackFrame)
        linfo = frame.linfo
        if linfo === nothing || ((get(io, :compacttrace, false) || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))) && parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))) #get(io, :minimaltrace, false))
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
else
    import Base.StackTraces:
        show_spec_sig

    function show_spec_linfo(io::IO, frame::StackFrame)
        linfo = frame.linfo
        if linfo === nothing || ((get(io, :compacttrace, false) || parse(Bool, get(ENV, "JULIA_STACKTRACE_ABBREVIATED", "false"))) && parse(Bool, get(ENV, "JULIA_STACKTRACE_MINIMAL", "false"))) #get(io, :minimaltrace, false))
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
end