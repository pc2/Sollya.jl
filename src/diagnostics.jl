# The public native message API exposes IDs and generic summaries, not formatted
# messages. All calls here run synchronously with the process library lock held.
mutable struct _DiagnosticContext
    messages::Vector{Pair{Int, String}}
    previous_callback::Ptr{Cvoid}
    previous_data::Ptr{Cvoid}
    display::Bool
end

function _collect_diagnostic(message::Ptr{Cvoid}, data::Ptr{Cvoid})::Cint
    # No Julia exception may cross the C callback boundary. Copy the message
    # while it is valid and free its text with Sollya's allocator.
    try
        context = unsafe_pointer_to_objref(data)::_DiagnosticContext
        try
            id = Int(ccall(_fn(:sollya_lib_get_msg_id), Cint, (Ptr{Cvoid},), message))
            if !any(item -> first(item) == id, context.messages)
                ptr =
                    ccall(_fn(:sollya_lib_msg_to_text), Ptr{UInt8}, (Ptr{Cvoid},), message)
                if ptr != C_NULL
                    try
                        text = unsafe_string(ptr)
                        length(context.messages) == 16 && popfirst!(context.messages)
                        push!(context.messages, id => text)
                    finally
                        ccall(_fn(:sollya_lib_free), Cvoid, (Ptr{Cvoid},), ptr)
                    end
                end
            end
        catch
            # Diagnostics are best effort; preserve the native operation.
        end
        if context.previous_callback != C_NULL
            return ccall(
                context.previous_callback,
                Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}),
                message,
                context.previous_data,
            )
        end
        return Cint(context.display)
    catch
        return Cint(1)
    end
end

# Resolve the callback address at runtime, after the function is defined.
_initialize_diagnostics!() = (
    _diagnostic_callback[] =
        @cfunction(_collect_diagnostic, Cint, (Ptr{Cvoid}, Ptr{Cvoid}))
)

# Scope this around the actual native operation, after argument conversion and
# before cleanup, so diagnostics from earlier operations cannot leak into errors.
function _with_diagnostics(f::F; raise_verbosity::Bool = true) where {F}
    callback, data = Ref{Ptr{Cvoid}}(C_NULL), Ref{Ptr{Cvoid}}(C_NULL)
    ccall(
        _fn(:sollya_lib_get_msg_callback),
        Cvoid,
        (Ref{Ptr{Cvoid}}, Ref{Ptr{Cvoid}}),
        callback,
        data,
    )
    previous = _owned(ccall(_fn(:sollya_lib_get_verbosity), Ptr{Cvoid}, ()), :get_verbosity)
    raised = nothing
    try
        verbosity = _exact_int(previous)
        raising = raise_verbosity && verbosity == 0 && callback[] == C_NULL
        context = _DiagnosticContext(Pair{Int, String}[], callback[], data[], !raising)
        if raising
            raised = SollyaObject(1)
            GC.@preserve raised ccall(
                _fn(:sollya_lib_set_verbosity),
                Cvoid,
                (Ptr{Cvoid},),
                _ptr(raised),
            )
        end
        GC.@preserve context begin
            try
                installed = ccall(
                    _fn(:sollya_lib_install_msg_callback),
                    Cint,
                    (Ptr{Cvoid}, Ptr{Cvoid}),
                    _diagnostic_callback[],
                    pointer_from_objref(context),
                )
                installed != 0 ||
                    throw(SollyaError(:diagnostics, "cannot install callback"))
                try
                    return f()
                catch err
                    if err isa SollyaError &&
                       isempty(err.diagnostics) &&
                       !isempty(context.messages)
                        throw(
                            SollyaError(err.operation, err.detail, copy(context.messages)),
                        )
                    end
                    rethrow()
                end
            finally
                if callback[] == C_NULL
                    ccall(_fn(:sollya_lib_uninstall_msg_callback), Cint, ())
                else
                    ccall(
                        _fn(:sollya_lib_install_msg_callback),
                        Cint,
                        (Ptr{Cvoid}, Ptr{Cvoid}),
                        callback[],
                        data[],
                    )
                end
            end
        end
    finally
        if raised !== nothing
            GC.@preserve previous ccall(
                _fn(:sollya_lib_set_verbosity),
                Cvoid,
                (Ptr{Cvoid},),
                _ptr(previous),
            )
            close(raised)
        end
        close(previous)
    end
end
