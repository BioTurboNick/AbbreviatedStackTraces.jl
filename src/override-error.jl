if isdefined(Base, :ExceptionStack)

    const oldversion = false
    import Base.ExceptionStack

else

    import Base:
        getindex,
        size

    const oldversion = true

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