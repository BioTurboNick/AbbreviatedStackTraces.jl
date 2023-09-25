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
