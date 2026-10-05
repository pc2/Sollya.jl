const ExactRational = Rational{BigInt}
const ExactBounds = Tuple{ExactRational,ExactRational}

"""
    ApproximationRequest(function_expr, (lower, upper); basis=5, formats=:single,
                         error=:absolute, arithmetic=:floating,
                         precision=256, accuracy=1//1024)

Serializable input for a coefficient-generation and norm-certification job.
Bounds and norm accuracy are stored exactly. No native object is created here.
For a scalar format, every selected monomial receives the same format.
"""
struct ApproximationRequest
    function_expr::String
    domain::ExactBounds
    basis::Union{Int,Vector{Int}}
    formats::Vector{Union{Int,Symbol}}
    error::Symbol
    arithmetic::Symbol
    precision::Int
    accuracy::ExactRational
    function ApproximationRequest(function_expr::AbstractString, domain::Tuple{Real,Real};
                                  basis=5, formats=:single, error::Symbol=:absolute,
                                  arithmetic::Symbol=:floating, precision::Integer=256,
                                  accuracy::Real=1//1024)
        occursin('\0', function_expr) && throw(ArgumentError("function expression cannot contain NUL"))
        lo, hi = Rational{BigInt}.(domain)
        lo <= hi || throw(ArgumentError("reversed request domain"))
        if basis isa Integer
            0 <= basis < typemax(Cint) || throw(ArgumentError("invalid degree"))
            stored_basis = Int(basis)
            count = stored_basis + 1
        elseif basis isa AbstractVector{<:Integer}
            isempty(basis) && throw(ArgumentError("empty monomial list"))
            all(k -> 0 <= k < typemax(Cint), basis) && issorted(basis) && allunique(basis) ||
                throw(ArgumentError("monomial exponents must be increasing nonnegative C ints"))
            stored_basis = Int.(basis)
            count = length(stored_basis)
        else
            throw(ArgumentError("basis must be a degree or monomial exponent vector"))
        end
        error ∈ (:absolute, :relative) || throw(ArgumentError("invalid error type"))
        arithmetic ∈ (:floating, :fixed) || throw(ArgumentError("invalid arithmetic"))
        items = formats isa AbstractVector ? collect(formats) : fill(formats, count)
        length(items) == count || throw(ArgumentError("expected $count formats"))
        stored_formats = Union{Int,Symbol}[]
        for item in items
            if item isa Integer
                typemin(Cint) <= item <= typemax(Cint) || throw(ArgumentError("invalid coefficient width"))
                arithmetic == :fixed || item >= 2 || throw(ArgumentError("significand width must be at least 2"))
                push!(stored_formats, Int(item))
            elseif item isa Symbol && haskey(_formats, item) && arithmetic == :floating
                push!(stored_formats, item)
            else
                throw(ArgumentError("invalid coefficient format: $item"))
            end
        end
        session = Session(; precision)
        acc = Rational{BigInt}(accuracy)
        0 < acc < 1 || throw(ArgumentError("norm accuracy must be in (0,1)"))
        new(String(function_expr), (lo, hi), stored_basis, stored_formats, error,
            arithmetic, session.precision, acc)
    end
end

"""
Serializable approximation result: exact ascending coefficients, a dyadic
polynomial expression, actual (possibly outward-enlarged) domain, norm enclosure,
error type and working precision. The certificate covers the mathematical
polynomial only, excluding evaluator rounding, reductions and reconstruction.
"""
struct ApproximationResult
    polynomial::String
    coefficients::Vector{ExactRational}
    domain::ExactBounds
    norm_bound::ExactBounds
    error::Symbol
    precision::Int
end

"""Generate coefficients and certify their approximation error, releasing native objects."""
function approximate(request::ApproximationRequest)
    with_session(Session(; precision=request.precision)) do
        owned = SollyaObject[]
        try
            f = sollya(request.function_expr)
            push!(owned, f)
            domain = interval(request.domain...)
            push!(owned, domain)
            p = fpminimax(f, request.basis, request.formats, domain;
                          error=request.error, arithmetic=request.arithmetic)
            push!(owned, p)
            certificate = supnorm(p, f, domain; error=request.error, accuracy=request.accuracy)
            push!(owned, certificate)
            return ApproximationResult(expression(p), coefficients(p), bounds(domain),
                                       bounds(certificate), request.error, working_precision())
        finally
            foreach(close, reverse(owned))
        end
    end
end

"""
    SollyaPool(n)
    SollyaPool(n) do pool
        approximate_many(pool, requests)
    end

Start `n` local Julia worker processes, each with its own Sollya global state.
The package project and resolved native library are forwarded to workers.
Use `close(pool)` or the do-block constructor to remove owned workers.
No worker processes start merely by importing Sollya.
"""
mutable struct SollyaPool
    workers::Vector{Int}
    pool::Distributed.CachingPool
    lock::ReentrantLock
    open::Bool
    SollyaPool(workers, pool, lock, open, ::Val{:owned}) = new(workers, pool, lock, open)
end

function SollyaPool(n::Integer)
    1 <= n <= typemax(Int) || throw(ArgumentError("worker count must be positive"))
    native = library_path()
    project = dirname(@__DIR__)
    flags = Cmd(["--project=$project", "--startup-file=no", "--threads=1"])
    ids = Distributed.addprocs(Int(n); exeflags=flags, env=["SOLLYA_LIBRARY" => native])
    try
        Distributed.remotecall_eval(Main, ids, :(using Sollya))
        return SollyaPool(ids, Distributed.CachingPool(ids), ReentrantLock(), true, Val(:owned))
    catch
        Distributed.rmprocs(ids)
        rethrow()
    end
end

function SollyaPool(f::F, n::Integer) where {F}
    pool = SollyaPool(n)
    try
        return f(pool)
    finally
        close(pool)
    end
end

Base.isopen(pool::SollyaPool) = pool.open
function Base.close(pool::SollyaPool)
    lock(pool.lock)
    try
        pool.open || return nothing
        Distributed.rmprocs(pool.workers)
        Distributed.clear!(pool.pool)
        pool.open = false
    finally
        unlock(pool.lock)
    end
    return nothing
end

"""
    approximate_many(pool, requests)

Run jobs concurrently in separate processes, preserving request order. Exceptions
propagate to the caller; failed proofs are never replaced with estimates. Only
serializable request/result data crosses process boundaries.
"""
function approximate_many(pool::SollyaPool, requests::AbstractVector{ApproximationRequest})
    lock(pool.lock)
    try
        pool.open || throw(ArgumentError("Sollya worker pool is closed"))
        return Distributed.pmap(approximate, pool.pool, requests; batch_size=1)
    finally
        unlock(pool.lock)
    end
end
