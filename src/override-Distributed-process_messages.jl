__precompile__(false)

import Base:
    showerror

import Distributed:
    myid,
    RemoteException

# copied from Distributed/process_messages.jl and added dealing with RemoteException
function showerror(io::IO, re::RemoteException)
    (re.pid != myid()) && print(io, "On worker ", re.pid, ":\n")
    showerror(IOContext(io, :compacttrace => false), re.captured)
end