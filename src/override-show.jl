__precompile__(false)

import Core:
    SimpleVector

import Base:
    show_datatype,
    show_type_name

function show_datatype(io::IO, @nospecialize(x::DataType))
    parameters = x.parameters::SimpleVector
    istuple = x.name === Tuple.name
    n = length(parameters)

    # Print homogeneous tuples with more than 3 elements compactly as NTuple{N, T}
    if istuple && n > 3 && all(i -> (parameters[1] === i), parameters)
        print(io, "NTuple{", n, ", ", parameters[1], "}")
    else
        show_type_name(io, x.name)
        if (n > 0 || istuple) && x !== Tuple
            # Do not print the type parameters for the primary type if we are
            # printing a method signature or type parameter.
            # Always print the type parameter if we are printing the type directly
            # since this information is still useful.
            print(io, '{')
            omitted = get(io, :compacttrace, false) && n > 2
            omitted && (n = 2)
            for i = 1:n
                p = parameters[i]
                show(io, p)
                i < n && print(io, ", ")
            end
            omitted && print(io, ", …")
            print(io, '}')
        end
    end
end

if VERSION < v"1.7-DEV"
    
    import Base:
        show_tuple_as_call

    show_tuple_as_call(io::IO, name::Symbol, sig::Type; demangle=false, kwargs=nothing, argnames=nothing, qualified=false, hasfirst=true) =
        Base.show_tuple_as_call(io, name, sig, demangle, kwargs, argnames, qualified)

end
