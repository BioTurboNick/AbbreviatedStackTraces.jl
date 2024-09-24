module AbbrvStackTracesDistributedExt

__precompile__(false)

import Distributed:
    myid,
    RemoteException

# copied from Distributed/process_messages.jl and added dealing with RemoteException
function Base.showerror(io::IO, re::RemoteException)
    (re.pid != myid()) && print(io, "On worker ", re.pid, ":\n")
    showerror(IOContext(io, :compacttrace => false), re.captured)
end

end
