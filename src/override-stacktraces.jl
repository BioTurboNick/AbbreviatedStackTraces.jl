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
    top_level_scope_sym

if VERSION < v"1.10-alpha1"
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
end

if v"1.10-DEV.0" < VERSION < v"1.10" || v"1.11-DEV.0" < VERSION < v"1.11-alpha"
    # Fix inline stack frames in development 1.10 and 1.11 releases
    Base.@constprop :none function lookup(pointer::Ptr{Cvoid})
        infos = ccall(:jl_lookup_code_address, Any, (Ptr{Cvoid}, Cint), pointer, false)::Core.SimpleVector
        pointer = convert(UInt64, pointer)
        isempty(infos) && return [Base.StackTraces.StackFrame(empty_sym, empty_sym, -1, nothing, true, false, pointer)] # this is equal to UNKNOWN
        parent_linfo = infos[end][4]
        inlinetable = Base.StackTraces.get_inlinetable(parent_linfo)
        miroots = inlinetable === nothing ? Base.StackTraces.get_method_instance_roots(parent_linfo) : nothing # fallback if linetable missing
        res = Vector{Base.StackTraces.StackFrame}(undef, length(infos))
        for i in reverse(1:length(infos))
            info = infos[i]::Core.SimpleVector
            @assert(length(info) == 6)
            func = info[1]::Symbol
            file = info[2]::Symbol
            linenum = info[3]::Int
            linfo = info[4]
            if i < length(infos)
                if inlinetable !== nothing
                    linfo = Base.StackTraces.lookup_inline_frame_info(func, file, linenum, inlinetable)
                elseif miroots !== nothing
                    linfo = Base.StackTraces.lookup_inline_frame_info(func, file, miroots)
                end
            end
            res[i] = Base.StackTraces.StackFrame(func, file, linenum, linfo, info[5]::Bool, info[6]::Bool, pointer)
        end
        return res
    end
end
