function _basis(value)
    if value isa Integer
        0 <= value < typemax(Cint) ||
            throw(ArgumentError("degree must be a nonnegative C int"))
        return SollyaObject(value), Int(value) + 1
    elseif value isa AbstractVector{<:Integer}
        isempty(value) && throw(ArgumentError("monomial list cannot be empty"))
        all(k -> 0 <= k < typemax(Cint), value) ||
            throw(ArgumentError("monomial exponents must be nonnegative C ints"))
        issorted(value) && allunique(value) ||
            throw(ArgumentError("monomial exponents must be strictly increasing"))
        return sollya_list(value), length(value)
    end
    throw(ArgumentError("basis must be a degree or a vector of monomial exponents"))
end

"""
    fpminimax(f, basis, formats, domain; error=:absolute, arithmetic=:floating,
              constrained=nothing, minimax=nothing)

Compute a polynomial with representable coefficients. `basis` is a degree or a
strictly increasing vector of monomial exponents. `formats` is a scalar repeated
for every coefficient or a vector of matching length. Floating integers specify
significand widths; fixed integers specify fractional widths (possibly negative).
Format symbols include `:halfprecision`, `:single`, `:double`, `:quad`.
`constrained` adds a fixed polynomial part; `minimax` supplies a polynomial or
`sollya_list` of coefficients as Sollya's optional last minimax seed. Omitting
`constrained` uses a zero fixed part, even when a seed is supplied. The result
still needs separate error certification.
"""
function fpminimax(
    f::SollyaObject,
    basis,
    formats,
    domain::SollyaObject;
    error::Symbol = :absolute,
    arithmetic::Symbol = :floating,
    constrained = nothing,
    minimax = nothing,
)
    isrange(domain) || throw(ArgumentError("fpminimax domain must be an interval"))
    _locked() do
        owned = SollyaObject[]
        try
            n, count = _basis(basis)
            push!(owned, n)
            items = formats isa AbstractVector ? collect(formats) : fill(formats, count)
            length(items) == count ||
                throw(ArgumentError("expected $count coefficient formats"))
            error ∈ (:absolute, :relative) ||
                throw(ArgumentError("error must be :absolute or :relative"))
            arithmetic ∈ (:fixed, :floating) ||
                throw(ArgumentError("arithmetic must be :fixed or :floating"))
            fmtobjects = SollyaObject[]
            for item in items
                obj = _format(item; fixed = arithmetic == :fixed)
                push!(owned, obj)
                push!(fmtobjects, obj)
            end
            fmt = sollya_list(fmtobjects)
            push!(owned, fmt)
            err = _indicator(error, (:absolute, :relative))
            push!(owned, err)
            arith = _indicator(arithmetic, (:fixed, :floating))
            push!(owned, arith)
            # Homogeneous pointer varargs, explicitly marked variadic for the
            # arm64 ABI. NULL terminates the optional arguments in Sollya.
            args = Any[f, n, fmt, domain, err, arith]
            # The seed must occupy argument eight; argument seven is a fixed
            # part, so supply zero there when only a seed was requested.
            if constrained !== nothing || minimax !== nothing
                push!(args, something(constrained, 0))
            end
            minimax === nothing || push!(args, minimax)
            return _withobjects(args...) do p
                p7 = length(p) >= 7 ? p[7] : C_NULL
                p8 = length(p) >= 8 ? p[8] : C_NULL
                _with_diagnostics() do
                    _owned(
                        ccall(
                            _fn(:sollya_lib_fpminimax),
                            Ptr{Cvoid},
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}...),
                            p[1],
                            p[2],
                            p[3],
                            p[4],
                            p[5],
                            p[6],
                            p7,
                            p8,
                            C_NULL,
                        ),
                        :fpminimax,
                    )
                end
            end
        finally
            foreach(close, reverse(owned))
        end
    end
end

"""
    remez(f, basis, domain; weight=nothing, quality=nothing, stop_bounds=nothing)

Approximate the minimax for `p*weight - f`; default weight is 1 (absolute error).
For relative approximation of g, use f=1 and weight=1/g. Basis is a degree or
monomial exponent vector. The computed polynomial is not an error certificate.
"""
function remez(
    f::SollyaObject,
    basis,
    domain::SollyaObject;
    weight = nothing,
    quality = nothing,
    stop_bounds = nothing,
)
    isrange(domain) || throw(ArgumentError("remez domain must be an interval"))
    _locked() do
        n, _ = _basis(basis)
        default = _indicator(:default, (:default,))
        try
            _withobjects(
                f,
                n,
                domain,
                something(weight, default),
                something(quality, default),
                something(stop_bounds, default),
            ) do p
                _with_diagnostics() do
                    _owned(
                        ccall(
                            _fn(:sollya_lib_remez),
                            Ptr{Cvoid},
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}...),
                            p[1],
                            p[2],
                            p[3],
                            p[4],
                            p[5],
                            p[6],
                            C_NULL,
                        ),
                        :remez,
                    )
                end
            end
        finally
            close(n)
            close(default)
        end
    end
end

function _validate_norm_accuracy(accuracy::Real)
    isfinite(accuracy) && 0 < accuracy < 1 ||
        throw(ArgumentError("norm accuracy must be a finite constant in (0,1)"))
    return nothing
end

function _validate_norm_accuracy(accuracy)
    obj = SollyaObject(accuracy)
    valid = try
        isfunction(obj) && all((
            (:sollya_lib_cmp_greater, 0),
            (:sollya_lib_cmp_less, 1),
        )) do (op, bound)
            comparison = _binary(op, obj, bound)
            try
                _predicate(:sollya_lib_is_true, comparison)
            finally
                close(comparison)
            end
        end
    catch e
        e isa SollyaError || rethrow()
        false
    finally
        close(obj)
    end
    valid || throw(ArgumentError("norm accuracy must be a finite constant in (0,1)"))
    return nothing
end

"""
    supnorm(p, f, domain; error=:absolute, accuracy=1//1024)

Return a certified enclosure of sup |p-f| (or |p/f-1| for relative error).
`accuracy` must be a finite constant in (0,1). It is the requested relative
tightness of the norm enclosure, not an acceptable approximation error. Invalid
accuracy throws `ArgumentError`. Native proof failure throws `SollyaError`;
there is no fallback to sampling. Sollya's smoothness/domain assumptions apply.
"""
function supnorm(
    p::SollyaObject,
    f::SollyaObject,
    domain::SollyaObject;
    error::Symbol = :absolute,
    accuracy = 1 // 1024,
)
    isrange(domain) || throw(ArgumentError("supnorm domain must be an interval"))
    _locked() do
        _validate_norm_accuracy(accuracy)
        err = _indicator(error, (:absolute, :relative))
        try
            _withobjects(p, f, domain, err, accuracy) do ptrs
                _with_diagnostics() do
                    result = _owned(
                        ccall(
                            _fn(:sollya_lib_supnorm),
                            Ptr{Cvoid},
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                            ptrs[1],
                            ptrs[2],
                            ptrs[3],
                            ptrs[4],
                            ptrs[5],
                        ),
                        :supnorm,
                    )
                    return _require_range(result, :supnorm)
                end
            end
        finally
            close(err)
        end
    end
end

"""Certified native infinity-norm enclosure. Prefer `supnorm` for polynomial error."""
function infnorm(f::SollyaObject, domain::SollyaObject)
    isrange(domain) || throw(ArgumentError("infnorm domain must be an interval"))
    _locked() do
        GC.@preserve f domain begin
            _require_range(
                _owned(
                    ccall(
                        _fn(:sollya_lib_infnorm),
                        Ptr{Cvoid},
                        (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}...),
                        _ptr(f),
                        _ptr(domain),
                        C_NULL,
                    ),
                    :infnorm,
                ),
                :infnorm,
            )
        end
    end
end

"""Estimate the infinity norm numerically. This is a diagnostic, never a certificate."""
dirtyinfnorm(f::SollyaObject, domain::SollyaObject) =
    _binary(:sollya_lib_dirtyinfnorm, f, domain)

"""Prove the strict infinity-norm bound if possible; false also covers inconclusive proof."""
function checkinfnorm(f::SollyaObject, domain::SollyaObject, bound)
    result = _ternary(:sollya_lib_checkinfnorm, f, domain, bound)
    try
        return _bool(result)
    finally
        close(result)
    end
end

"""Return Sollya's degree-search interval; this remains a planning aid, not a certificate."""
function guessdegree(
    f::SollyaObject,
    domain::SollyaObject,
    target;
    weight = nothing,
    maxdegree::Integer = 128,
)
    1 <= maxdegree <= typemax(Cint) || throw(ArgumentError("maxdegree must be positive"))
    _locked() do
        default = _indicator(:default, (:default,))
        try
            _withobjects(f, domain, target, something(weight, default), maxdegree) do p
                _require_range(
                    _owned(
                        ccall(
                            _fn(:sollya_lib_guessdegree),
                            Ptr{Cvoid},
                            (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}...),
                            p[1],
                            p[2],
                            p[3],
                            p[4],
                            p[5],
                            C_NULL,
                        ),
                        :guessdegree,
                    ),
                    :guessdegree,
                )
            end
        finally
            close(default)
        end
    end
end

"""Return Sollya's list of certified zero enclosures (subject to native assumptions)."""
findzeros(f::SollyaObject, domain::SollyaObject) = _binary(:sollya_lib_findzeros, f, domain)
"""Return numerically estimated zeros; these are not certified enclosures."""
dirtyfindzeros(f::SollyaObject, domain::SollyaObject) =
    _binary(:sollya_lib_dirtyfindzeros, f, domain)
