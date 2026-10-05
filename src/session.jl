"""
    Session(; precision=256, verbosity=0, points=nothing, diameter=nothing)

Serializable settings for a scoped computation. A Session is not an independent
native context: Sollya has one global state per process. Use `with_session` to
hold the process lock and restore all these settings on success or exception.
Precision must be at least 12 bits and `points` at least 3. `diameter`, if
provided, must be a positive rational subdivision threshold.
"""
struct Session
    precision::Int
    verbosity::Int
    points::Union{Nothing,Int}
    diameter::Union{Nothing,Rational{BigInt}}
    function Session(; precision::Integer=256, verbosity::Integer=0,
                     points::Union{Nothing,Integer}=nothing,
                     diameter::Union{Nothing,Rational}=nothing)
        12 <= precision <= typemax(Cint) || throw(ArgumentError("precision must be in 12:$(typemax(Cint))"))
        0 <= verbosity <= typemax(Cint) || throw(ArgumentError("verbosity must be nonnegative"))
        points === nothing || 3 <= points <= typemax(Cint) || throw(ArgumentError("points must be at least 3"))
        diameter === nothing || 0 < diameter <= 1 || throw(ArgumentError("diameter must be in (0,1]"))
        new(Int(precision), Int(verbosity), points === nothing ? nothing : Int(points),
            diameter === nothing ? nothing : Rational{BigInt}(diameter))
    end
end

"""
    with_session([session]) do
        # Sollya work
    end

Apply settings, serialize the whole callback and restore settings in `finally`.
Nested sessions on the same task are supported. Do not wait inside this callback
for another task that needs Sollya in this process: it would wait on this lock.
"""
function with_session(f::F, session::Session=Session()) where {F}
    _locked() do
        settings = Pair{Symbol,Any}[:prec => session.precision, :verbosity => session.verbosity]
        session.points === nothing || push!(settings, :points => session.points)
        session.diameter === nothing || push!(settings, :diam => session.diameter)
        previous = Pair{Symbol,Ptr{Cvoid}}[]
        try
            for (name, value) in settings
                old = ccall(_fn(Symbol(:sollya_lib_get_, name)), Ptr{Cvoid}, ())
                push!(previous, name => old)
                obj = SollyaObject(value)
                try
                    GC.@preserve obj ccall(_fn(Symbol(:sollya_lib_set_, name)), Cvoid,
                                           (Ptr{Cvoid},), _ptr(obj))
                finally
                    close(obj)
                end
            end
            return f()
        finally
            for (name, obj) in reverse(previous)
                ccall(_fn(Symbol(:sollya_lib_set_, name)), Cvoid, (Ptr{Cvoid},), obj)
                ccall(_fn(:sollya_lib_clear_obj), Cvoid, (Ptr{Cvoid},), obj)
            end
        end
    end
end

"""Return the process's current Sollya working precision in bits."""
function working_precision()
    _locked() do
        obj = _owned(ccall(_fn(:sollya_lib_get_prec), Ptr{Cvoid}, ()), :get_prec)
        try
            return _exact_int(obj)
        finally
            close(obj)
        end
    end
end
