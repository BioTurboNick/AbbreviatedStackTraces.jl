show_tuple_as_call(io::IO, name::Symbol, sig::Type; demangle=false, kwargs=nothing, argnames=nothing, qualified=false, hasfirst=true) =
    Base.show_tuple_as_call(io, name, sig, demangle, kwargs, argnames, qualified)
