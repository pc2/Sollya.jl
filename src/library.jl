const _library_lock = ReentrantLock()
const _library_handle = Ref{Ptr{Cvoid}}(C_NULL)
const _library_path = Ref("")
const _symbols = Dict{Symbol,Ptr{Cvoid}}()

"""An operation returned Sollya's `error` object or failed its native conversion."""
struct SollyaError <: Exception
    operation::Symbol
    detail::String
end
Base.showerror(io::IO, e::SollyaError) = print(io, "Sollya ", e.operation, ": ", e.detail)

function __init__()
    _library_handle[] = C_NULL
    _library_path[] = ""
    empty!(_symbols)
    empty!(_pending_finalizers)
end

function _load_library!()
    _library_handle[] != C_NULL && return
    override = get(ENV, "SOLLYA_LIBRARY", "")
    candidates = isempty(override) ? [
        "libsollya", "libsollya.so.8", "libsollya.8.dylib",
        "/opt/homebrew/opt/sollya/lib/libsollya.dylib",
        "/usr/local/opt/sollya/lib/libsollya.dylib",
    ] : [override]
    for candidate in candidates
        handle = Libdl.dlopen(candidate; throw_error=false)
        handle === nothing && continue
        init = Libdl.dlsym(handle, :sollya_lib_init; throw_error=false)
        if init === nothing
            Libdl.dlclose(handle)
            continue
        end
        # Sollya returns 1 on first initialization, 0 when already initialized.
        status = ccall(init, Cint, ())
        if status ∉ (0, 1)
            Libdl.dlclose(handle)
            throw(SollyaError(:init, "unexpected native status $status"))
        end
        _library_handle[] = handle
        _library_path[] = Libdl.dlpath(handle)
        return
    end
    throw(ArgumentError("Cannot load libsollya. Install Sollya 8.0 and set " *
                        "SOLLYA_LIBRARY to the shared library's absolute path before first use."))
end

# Every lookup and call is made with _library_lock held. No native address is
# saved into a precompile image. Keep the library initialized for process life:
# global shutdown would invalidate live objects, including other library users.
function _fn(symbol::Symbol)
    get!(_symbols, symbol) do
        Libdl.dlsym(_library_handle[], symbol)
    end
end

function _locked(f::F) where {F}
    lock(_library_lock)
    try
        _load_library!()
        _drain_finalizers!()
        return f()
    finally
        unlock(_library_lock)
    end
end

"""Return the actual shared library loaded in this process (loading it lazily)."""
library_path() = _locked(() -> _library_path[])
