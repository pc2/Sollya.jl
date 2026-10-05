const _finalizer_lock = Threads.SpinLock()
const _pending_finalizers = Ptr{Cvoid}[]

"""
    SollyaObject(value)

An owning, process-local Sollya object. Strings are parsed as Sollya expressions;
integers, rationals and binary floating point values are imported exactly.
Use `close(obj)` for deterministic release. A finalizer schedules deferred cleanup.
Objects cannot be serialized; transfer exact rationals or expressions to workers.
"""
mutable struct SollyaObject
    ptr::Ptr{Cvoid}
    const process::Int
    # Native pointers can only enter through the internal owning constructor.
    SollyaObject(ptr::Ptr{Cvoid}, process::Int, ::Val{:owned}) = new(ptr, process)
end

function _ptr(obj::SollyaObject)
    obj.process == getpid() ||
        throw(ArgumentError("Sollya objects belong to their creating process"))
    obj.ptr != C_NULL || throw(ArgumentError("Sollya object is closed"))
    return obj.ptr
end

function _owned(ptr::Ptr{Cvoid}, operation::Symbol)
    ptr == C_NULL && throw(SollyaError(operation, "native call returned NULL"))
    if ccall(_fn(:sollya_lib_obj_is_error), Cint, (Ptr{Cvoid},), ptr) != 0
        ccall(_fn(:sollya_lib_clear_obj), Cvoid, (Ptr{Cvoid},), ptr)
        throw(SollyaError(operation, "native call returned error"))
    end
    obj = SollyaObject(ptr, Int(getpid()), Val(:owned))
    finalizer(_finalize!, obj)
    return obj
end

# Finalizers must not block on a ReentrantLock or enter the non-thread-safe
# library. The spin lock protects only pointer detachment and a small queue.
# Actual native frees happen at the next serialized entry into Sollya.
function _finalize!(obj::SollyaObject)
    obj.process == getpid() || return
    lock(_finalizer_lock)
    try
        if obj.ptr != C_NULL
            push!(_pending_finalizers, obj.ptr)
            obj.ptr = C_NULL
        end
    finally
        unlock(_finalizer_lock)
    end
    return nothing
end

function _drain_finalizers!()
    lock(_finalizer_lock)
    pending = try
        isempty(_pending_finalizers) && return nothing
        items = copy(_pending_finalizers)
        empty!(_pending_finalizers)
        items
    finally
        unlock(_finalizer_lock)
    end
    for ptr in pending
        ccall(_fn(:sollya_lib_clear_obj), Cvoid, (Ptr{Cvoid},), ptr)
    end
    return nothing
end

"""Release native objects queued by finalizers. Explicit `close` does not need this."""
drain_finalizers!() = _locked(() -> nothing)

function Base.close(obj::SollyaObject)
    obj.process == getpid() ||
        throw(ArgumentError("Sollya object belongs to another process"))
    _locked() do
        lock(_finalizer_lock)
        ptr = try
            p = obj.ptr
            obj.ptr = C_NULL
            p
        finally
            unlock(_finalizer_lock)
        end
        ptr == C_NULL || ccall(_fn(:sollya_lib_clear_obj), Cvoid, (Ptr{Cvoid},), ptr)
    end
    return nothing
end
Base.isopen(obj::SollyaObject) = obj.process == getpid() && obj.ptr != C_NULL

function Serialization.serialize(::Serialization.AbstractSerializer, ::SollyaObject)
    throw(
        ArgumentError(
            "Cannot serialize native Sollya objects; use exact_rational, " *
            "coefficients, or an ApproximationRequest/ApproximationResult",
        ),
    )
end

"""Parse and evaluate a Sollya expression. Invalid expressions throw `SollyaError`."""
function sollya(text::AbstractString)
    occursin('\0', text) && throw(ArgumentError("Sollya expressions cannot contain NUL"))
    _locked() do
        _owned(ccall(_fn(:sollya_lib_parse_string), Ptr{Cvoid}, (Cstring,), text), :parse)
    end
end
SollyaObject(text::AbstractString) = sollya(text)
Base.parse(::Type{SollyaObject}, text::AbstractString) = sollya(text)

"""The literal `sollya"sin(x)"` parses its expression when executed, not at precompile time."""
macro sollya_str(text)
    :(sollya($text))
end

SollyaObject(obj::SollyaObject) = copy(obj)
function SollyaObject(value::Integer)
    if typemin(Int64) <= value <= typemax(Int64)
        return _locked() do
            _owned(
                ccall(_fn(:sollya_lib_constant_from_int64), Ptr{Cvoid}, (Int64,), value),
                :constant,
            )
        end
    end
    return sollya(string(value))
end
function SollyaObject(value::Rational)
    return sollya("($(numerator(value)))/($(denominator(value)))")
end
function SollyaObject(value::Union{Float16, Float32, Float64})
    _locked() do
        _owned(
            ccall(_fn(:sollya_lib_constant_from_double), Ptr{Cvoid}, (Cdouble,), value),
            :constant,
        )
    end
end
function SollyaObject(value::AbstractFloat)
    isfinite(value) || return SollyaObject(Float64(value))
    return SollyaObject(Rational{BigInt}(value))
end

function Base.copy(obj::SollyaObject)
    _locked() do
        GC.@preserve obj begin
            _owned(
                ccall(_fn(:sollya_lib_copy_obj), Ptr{Cvoid}, (Ptr{Cvoid},), _ptr(obj)),
                :copy,
            )
        end
    end
end

function _withobjects(f::F, args...) where {F}
    objects = SollyaObject[]
    temporaries = SollyaObject[]
    try
        for arg in args
            obj = arg isa SollyaObject ? arg : SollyaObject(arg)
            push!(objects, obj)
            arg isa SollyaObject || push!(temporaries, obj)
        end
        GC.@preserve objects begin
            return f(map(_ptr, objects))
        end
    finally
        foreach(close, temporaries)
    end
end

function _unary(symbol::Symbol, obj::SollyaObject)
    _locked() do
        GC.@preserve obj begin
            _owned(ccall(_fn(symbol), Ptr{Cvoid}, (Ptr{Cvoid},), _ptr(obj)), symbol)
        end
    end
end

function _binary(symbol::Symbol, a, b)
    _locked() do
        _withobjects(a, b) do p
            _owned(
                ccall(_fn(symbol), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), p[1], p[2]),
                symbol,
            )
        end
    end
end

function _ternary(symbol::Symbol, a, b, c)
    _locked() do
        _withobjects(a, b, c) do p
            _owned(
                ccall(
                    _fn(symbol),
                    Ptr{Cvoid},
                    (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                    p[1],
                    p[2],
                    p[3],
                ),
                symbol,
            )
        end
    end
end

function _predicate(symbol::Symbol, obj::SollyaObject)
    _locked() do
        GC.@preserve obj begin
            ccall(_fn(symbol), Cint, (Ptr{Cvoid},), _ptr(obj)) != 0
        end
    end
end

"""Whether this object is a mathematical function (including constants)."""
isfunction(obj::SollyaObject) = _predicate(:sollya_lib_obj_is_function, obj)
"""Whether this object is an interval."""
isrange(obj::SollyaObject) = _predicate(:sollya_lib_obj_is_range, obj)
"""Whether this object is a Sollya list."""
islist(obj::SollyaObject) = _predicate(:sollya_lib_obj_is_list, obj)

"""
    expression(obj; display=:dyadic)

Print a Sollya expression with an explicit display mode, restoring the global
display setting. Dyadic output preserves stored binary constants exactly.
Printing is not an exact conversion of an unevaluated irrational constant.
"""
function expression(obj::SollyaObject; display::Symbol = :dyadic)
    display ∈ (:dyadic, :decimal, :hexadecimal, :binary, :powers) ||
        throw(ArgumentError("unsupported display mode: $display"))
    _locked() do
        previous = ccall(_fn(:sollya_lib_get_display), Ptr{Cvoid}, ())
        mode = ccall(_fn(Symbol(:sollya_lib_, display)), Ptr{Cvoid}, ())
        try
            ccall(_fn(:sollya_lib_set_display), Cvoid, (Ptr{Cvoid},), mode)
            GC.@preserve obj begin
                ptr = _ptr(obj)
                size = ccall(
                    _fn(:sollya_lib_snprintf),
                    Cint,
                    (Ptr{UInt8}, Csize_t, Cstring, Ptr{Cvoid}...),
                    C_NULL,
                    0,
                    "%b",
                    ptr,
                )
                size >= 0 || throw(SollyaError(:print, "native snprintf failed"))
                buffer = Vector{UInt8}(undef, size + 1)
                written = ccall(
                    _fn(:sollya_lib_snprintf),
                    Cint,
                    (Ptr{UInt8}, Csize_t, Cstring, Ptr{Cvoid}...),
                    buffer,
                    length(buffer),
                    "%b",
                    ptr,
                )
                written == size ||
                    throw(SollyaError(:print, "inconsistent native snprintf result"))
                return String(buffer[1:size])
            end
        finally
            ccall(_fn(:sollya_lib_set_display), Cvoid, (Ptr{Cvoid},), previous)
            ccall(_fn(:sollya_lib_clear_obj), Cvoid, (Ptr{Cvoid},), mode)
            ccall(_fn(:sollya_lib_clear_obj), Cvoid, (Ptr{Cvoid},), previous)
        end
    end
end
function Base.show(io::IO, obj::SollyaObject)
    if isopen(obj)
        print(io, "SollyaObject(", repr(expression(obj)), ")")
    else
        print(io, "SollyaObject(<closed>)")
    end
end

# GMP's public ABI: mpz = {int alloc, int size, limb*}; mpq = {mpz num, mpz den}.
# Resolve GMP symbols through Sollya's library handle, so its allocator is used.
# Never pass Julia BigInt/BigFloat internals to a possibly different native GMP.
struct _NativeMPZ
    alloc::Cint
    size::Cint
    limbs::Ptr{Cvoid}
end
struct _NativeMPQ
    num::_NativeMPZ
    den::_NativeMPZ
end

"""
    exact_rational(obj) -> Rational{BigInt}

Extract a finite, provably rational constant using Sollya's exact MPQ conversion.
Rejects intervals, irrational expressions, infinities and NaN instead of rounding.
"""
function exact_rational(obj::SollyaObject)
    _locked() do
        zero_z = _NativeMPZ(0, 0, C_NULL)
        q = Ref(_NativeMPQ(zero_z, zero_z))
        ccall(_fn(:__gmpq_init), Cvoid, (Ref{_NativeMPQ},), q)
        try
            GC.@preserve obj q begin
                ok = ccall(
                    _fn(:sollya_lib_get_constant_as_mpq),
                    Cint,
                    (Ref{_NativeMPQ}, Ptr{Cvoid}),
                    q,
                    _ptr(obj),
                )
                ok != 0 ||
                    throw(SollyaError(:exact_rational, "not a finite rational constant"))
                p = Ptr{UInt8}(Base.unsafe_convert(Ptr{_NativeMPQ}, q))
                n = ccall(_fn(:__gmpz_sizeinbase), Csize_t, (Ptr{Cvoid}, Cint), p, 10)
                d = ccall(
                    _fn(:__gmpz_sizeinbase),
                    Csize_t,
                    (Ptr{Cvoid}, Cint),
                    p + fieldoffset(_NativeMPQ, 2),
                    10,
                )
                buffer = Vector{UInt8}(undef, Int(n + d + 4))
                ccall(
                    _fn(:__gmpq_get_str),
                    Ptr{UInt8},
                    (Ptr{UInt8}, Cint, Ref{_NativeMPQ}),
                    buffer,
                    10,
                    q,
                )
                text = GC.@preserve buffer unsafe_string(pointer(buffer))
                parts = split(text, '/')
                numerator = parse(BigInt, parts[1])
                denominator = length(parts) == 1 ? BigInt(1) : parse(BigInt, parts[2])
                return numerator // denominator
            end
        finally
            ccall(_fn(:__gmpq_clear), Cvoid, (Ref{_NativeMPQ},), q)
        end
    end
end

"""Convert approximately to Float64; this is not a directed error bound."""
function Base.Float64(obj::SollyaObject)
    _locked() do
        result = Ref{Cdouble}()
        GC.@preserve obj begin
            ok = ccall(
                _fn(:sollya_lib_get_constant_as_double),
                Cint,
                (Ref{Cdouble}, Ptr{Cvoid}),
                result,
                _ptr(obj),
            )
            ok != 0 ||
                throw(SollyaError(:Float64, "not convertible to a floating constant"))
            return result[]
        end
    end
end
Base.convert(::Type{Float64}, obj::SollyaObject) = Float64(obj)
Base.convert(::Type{Rational{BigInt}}, obj::SollyaObject) = exact_rational(obj)

function _exact_int(obj::SollyaObject)
    q = exact_rational(obj)
    denominator(q) == 1 || throw(SollyaError(:integer, "not an exact integer"))
    return Int(numerator(q))
end
