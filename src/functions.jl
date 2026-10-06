"""Create the free mathematical variable (printed as `_x_` by the library)."""
variable() =
    _locked(() -> _owned(ccall(_fn(:sollya_lib_free_variable), Ptr{Cvoid}, ()), :variable))

"""
    zero(SollyaObject)
    zero(obj::SollyaObject)

Create an owning exact zero. The type form returns a scalar constant. The instance
form accepts scalar constants and expressions, or returns `[0;0]` for an interval.
Lists and other nonnumeric objects are rejected with `ArgumentError`.
"""
Base.zero(::Type{SollyaObject}) = SollyaObject(0)
Base.zero(obj::SollyaObject) = _identity_object(obj, 0)

"""
    one(SollyaObject)
    one(obj::SollyaObject)

Create an owning exact one. The type form returns a scalar constant. The instance
form accepts scalar constants and expressions, or returns `[1;1]` for an interval.
Lists and other nonnumeric objects are rejected with `ArgumentError`.
"""
Base.one(::Type{SollyaObject}) = SollyaObject(1)
Base.one(obj::SollyaObject) = _identity_object(obj, 1)

function _identity_object(obj::SollyaObject, value::Int)
    _locked() do
        isfunction(obj) && return SollyaObject(value)
        isrange(obj) && return interval(value)
        throw(ArgumentError("zero and one require a scalar expression or interval"))
    end
end

for (op, native) in ((:+, :add), (:-, :sub), (:*, :mul), (:/, :div), (:^, :pow))
    symbol = Symbol(:sollya_lib_, native)
    @eval begin
        Base.$op(a::SollyaObject, b::SollyaObject) = _binary($(QuoteNode(symbol)), a, b)
        Base.$op(a::SollyaObject, b::Real) = _binary($(QuoteNode(symbol)), a, b)
        Base.$op(a::Real, b::SollyaObject) = _binary($(QuoteNode(symbol)), a, b)
    end
end
Base.:-(obj::SollyaObject) = _unary(:sollya_lib_neg, obj)
Base.:+(obj::SollyaObject) = copy(obj)
# Resolve the Base integer-power specialization explicitly.
Base.:^(obj::SollyaObject, exponent::Integer) = _binary(:sollya_lib_pow, obj, exponent)

for name in (
    :sqrt,
    :exp,
    :log,
    :log2,
    :log10,
    :sin,
    :cos,
    :tan,
    :asin,
    :acos,
    :atan,
    :sinh,
    :cosh,
    :tanh,
    :asinh,
    :acosh,
    :atanh,
    :abs,
    :log1p,
    :expm1,
    :ceil,
    :floor,
)
    symbol = Symbol(:sollya_lib_, name)
    @eval Base.$name(obj::SollyaObject) = _unary($(QuoteNode(symbol)), obj)
end

for (name, native, doc) in (
    (:erf, :erf, "Build a symbolic error function expression."),
    (:erfc, :erfc, "Build a symbolic complementary error function expression."),
    (:differentiate, :diff, "Differentiate with respect to the free variable."),
    (:horner, :horner, "Rewrite a polynomial in Horner form."),
    (:canonical, :canonical, "Rewrite a polynomial in canonical form."),
    (:expand, :expand, "Expand the expression without introducing rounding."),
    (:simplify, :simplify, "Apply Sollya's error-free simplification."),
    (:infimum, :inf, "Return the exact stored lower interval endpoint as a Sollya object."),
    (
        :supremum,
        :sup,
        "Return the exact stored upper interval endpoint as a Sollya object.",
    ),
    (:midpoint, :mid, "Return Sollya's interval midpoint."),
)
    symbol = Symbol(:sollya_lib_, native)
    @eval begin
        @doc $doc $name(obj::SollyaObject) = _unary($(QuoteNode(symbol)), obj)
    end
end

function _bool(obj::SollyaObject)
    _predicate(:sollya_lib_is_true, obj) && return true
    _predicate(:sollya_lib_is_false, obj) && return false
    throw(SollyaError(:boolean, "result is not a decidable Boolean"))
end

"""
    equal(a, b)

Return Sollya's native `==` result. This is not a certified mathematical equality
test: `false` can mean equality was not established, and `true` can rely on
numerical evaluation that did not prove equality. Results depend on native
precision and simplification settings; warnings may be hidden at verbosity zero.
Only a non-Boolean native result throws `SollyaError`.

Use [`structurally_equal`](@ref) to compare native object representations without
numerically testing equality. Julia object identity and hashing are unchanged.
"""
function equal(a, b)
    result = _binary(:sollya_lib_cmp_equal, a, b)
    try
        return _bool(result)
    finally
        close(result)
    end
end

"""
    structurally_equal(a, b)

Compare native object representations without numerically testing equality.
Arguments are imported through `SollyaObject` when needed, as with [`equal`](@ref).
This compares the stored structure after construction and simplification, not
the original source text. Algebraically equivalent expressions can have different
structures; `false` does not prove mathematical inequality. Two native NaNs have
the same structure and compare `true` here.

For example, two independently constructed `π * x` expressions compare `true`.
This does not change Julia object identity, `isequal`, or hashing.
"""
function structurally_equal(a, b)
    _locked() do
        _withobjects(a, b) do p
            ccall(
                _fn(:sollya_lib_cmp_objs_structurally),
                Cint,
                (Ptr{Cvoid}, Ptr{Cvoid}),
                p[1],
                p[2],
            ) != 0
        end
    end
end

function _require_range(obj::SollyaObject, operation::Symbol)
    isrange(obj) && return obj
    close(obj)
    throw(SollyaError(operation, "expected an interval result"))
end

"""
    interval(lower, upper=lower)

Build an outward-rounded interval. Exact dyadic bounds are preserved; non-dyadic
or irrational bounds may be enlarged at the current working precision.
Reversed endpoints are rejected rather than silently sorted.
"""
function interval(lower, upper = lower)
    _locked() do
        comparison = _binary(:sollya_lib_cmp_greater, lower, upper)
        try
            _bool(comparison) &&
                throw(ArgumentError("lower interval endpoint exceeds upper endpoint"))
        finally
            close(comparison)
        end
        return _require_range(_binary(:sollya_lib_range, lower, upper), :interval)
    end
end

"""Return finite interval endpoints exactly as `(Rational{BigInt}, Rational{BigInt})`."""
function bounds(obj::SollyaObject)
    isrange(obj) || throw(ArgumentError("bounds requires an interval"))
    lo, hi = infimum(obj), supremum(obj)
    try
        return (exact_rational(lo), exact_rational(hi))
    finally
        close(lo)
        close(hi)
    end
end

"""
    bounds(BigFloat, obj::SollyaObject; precision=precision(BigFloat))

Return finite interval endpoints as `(BigFloat, BigFloat)`, rounding the stored
lower endpoint down and the upper endpoint up to preserve the enclosure. Both
endpoints use the requested precision, defaulting to Julia's current precision.
Ignores Julia's rounding mode and changes neither Julia nor Sollya settings.
As with `bounds(obj)`, non-interval inputs raise `ArgumentError` and non-finite
endpoints raise `SollyaError`.
"""
function bounds(
    ::Type{BigFloat},
    obj::SollyaObject;
    precision::Integer = Base.precision(BigFloat),
)
    lo, hi = bounds(obj)
    return (
        _rounded_bigfloat(lo, RoundDown, precision),
        _rounded_bigfloat(hi, RoundUp, precision),
    )
end

"""
    sollya_list(values)

Build a finite list, copying each input object. The caller retains input ownership.
List indexing is one-based in Julia. Indexed elements are new owning objects.
"""
function sollya_list(values)
    args = collect(values)
    length(args) <= typemax(Cint) || throw(ArgumentError("list is too long"))
    _locked() do
        _withobjects(args...) do ptrs
            _owned(
                ccall(
                    _fn(:sollya_lib_list),
                    Ptr{Cvoid},
                    (Ptr{Ptr{Cvoid}}, Cint),
                    ptrs,
                    length(ptrs),
                ),
                :list,
            )
        end
    end
end

function Base.length(obj::SollyaObject)
    islist(obj) || throw(ArgumentError("length requires a Sollya list"))
    # Empty lists are also flagged end-elliptic; native length correctly gives 0.
    result = _unary(:sollya_lib_length, obj)
    try
        return _exact_int(result)
    finally
        close(result)
    end
end
function Base.getindex(obj::SollyaObject, index::Integer)
    _locked() do
        1 <= index <= length(obj) || throw(BoundsError(obj, index))
        result = Ref{Ptr{Cvoid}}(C_NULL)
        GC.@preserve obj begin
            ok = ccall(
                _fn(:sollya_lib_get_element_in_list),
                Cint,
                (Ref{Ptr{Cvoid}}, Ptr{Cvoid}, Cint),
                result,
                _ptr(obj),
                index - 1,
            )
            ok != 0 || throw(SollyaError(:getindex, "native list indexing failed"))
            return _owned(result[], :getindex)
        end
    end
end
Base.iterate(obj::SollyaObject, state::Int = 1) =
    state > length(obj) ? nothing : (obj[state], state + 1)
Base.eltype(::Type{SollyaObject}) = SollyaObject
Base.IteratorSize(::Type{SollyaObject}) = Base.HasLength()
# Only native lists broadcast elementwise; other objects are scalar values.
Base.broadcastable(obj::SollyaObject) = islist(obj) ? collect(obj) : Ref(obj)

"""
    evaluate(f, argument)

Native evaluation: point constants are evaluated faithfully at working precision;
interval arguments produce guaranteed image enclosures. A constant result is
not a correctly rounded reference. Use `enclosure` for certified point bounds.
"""
evaluate(f::SollyaObject, argument) = _binary(:sollya_lib_evaluate, f, argument)

"""Return a guaranteed image enclosure, using a singleton interval for point inputs."""
function enclosure(f::SollyaObject, argument)
    _locked() do
        own = !(argument isa SollyaObject && isrange(argument))
        domain = own ? interval(argument) : argument
        try
            return _require_range(evaluate(f, domain), :enclosure)
        finally
            own && close(domain)
        end
    end
end

"""Substitute an expression for the free variable without numerical evaluation."""
substitute(f::SollyaObject, argument) = _binary(:sollya_lib_substitute, f, argument)

"""Return the polynomial degree as an exact Julia Int; reject non-polynomials."""
function degree(obj::SollyaObject)
    result = _unary(:sollya_lib_degree, obj)
    try
        d = _exact_int(result)
        d >= 0 || throw(SollyaError(:degree, "expression is not a polynomial"))
        return d
    finally
        close(result)
    end
end

"""Return coefficient of `x^index` (zero-based). Reject non-polynomials."""
function coeff(obj::SollyaObject, index::Integer)
    index >= 0 || throw(ArgumentError("coefficient index must be nonnegative"))
    degree(obj) # Native coeff(exp(x), k) silently returns zero: reject that case.
    return _binary(:sollya_lib_coeff, obj, index)
end

"""Export finite rational coefficients exactly in ascending order, including internal zeros."""
coefficients(obj::SollyaObject) = _map_coefficients(exact_rational, obj)

function _map_coefficients(f::F, obj::SollyaObject) where {F}
    _locked() do
        d = degree(obj)
        # Native Sollya reports degree zero for the zero polynomial.
        return [
            begin
                c = _binary(:sollya_lib_coeff, obj, k)
                try
                    f(c)
                finally
                    close(c)
                end
            end for k = 0:max(0, d)
        ]
    end
end

"""
    coefficients(BigFloat, obj::SollyaObject, mode=rounding(BigFloat);
                 precision=precision(BigFloat), max_work_precision=nothing)

Export finite real polynomial coefficients as a `Vector{BigFloat}` in
ascending order, including internal zeros. Each coefficient is correctly rounded
using `BigFloat(c, mode; precision, max_work_precision)`, including symbolic
coefficients such as π or sqrt(2). The refinement limit applies independently
to each coefficient and has the same default as `BigFloat` conversion.
Defaults to Julia's current settings. Julia's settings are unchanged, and
temporary Sollya settings are restored on success or failure. Rejects
non-polynomials, non-finite coefficients and uncertifiable rounding with
`SollyaError`; no partial vector is returned if a coefficient fails.

`coefficients(obj)` continues to require exact rational coefficients.

Rounding can change the polynomial; an existing certificate for `obj` does not
automatically certify the rounded coefficients.
"""
function coefficients(
    ::Type{BigFloat},
    obj::SollyaObject,
    mode::RoundingMode = rounding(BigFloat);
    precision::Integer = Base.precision(BigFloat),
    max_work_precision::Union{Nothing, Integer} = nothing,
)
    return _map_coefficients(obj) do c
        BigFloat(c, mode; precision, max_work_precision)
    end
end

const _formats = Dict(
    :halfprecision => :sollya_lib_halfprecision_obj,
    :single => :sollya_lib_single_obj,
    :double => :sollya_lib_double_obj,
    :doubleextended => :sollya_lib_doubleextended_obj,
    :quad => :sollya_lib_quad_obj,
    :double_double => :sollya_lib_double_double_obj,
    :triple_double => :sollya_lib_triple_double_obj,
)
function _indicator(value::Symbol, allowed)
    value ∈ allowed || throw(ArgumentError("expected one of $allowed; got $value"))
    return _owned(ccall(_fn(Symbol(:sollya_lib_, value)), Ptr{Cvoid}, ()), value)
end
function _format(value; fixed::Bool = false)
    if value isa Integer
        (fixed || value >= 2) ||
            throw(ArgumentError("floating coefficient precision must be at least 2"))
        typemin(Cint) <= value <= typemax(Cint) ||
            throw(ArgumentError("format width is outside C int range"))
        return SollyaObject(value)
    elseif value isa Symbol && haskey(_formats, value)
        fixed && throw(
            ArgumentError("fixed coefficient formats must be integer fractional widths"),
        )
        return _owned(ccall(_fn(_formats[value]), Ptr{Cvoid}, ()), :format)
    end
    throw(ArgumentError("unsupported coefficient format: $value"))
end

"""
    round_to(obj, format; mode=:nearest)

Round using Sollya: `format` is a significand width or a format symbol such as
`:single`. Modes: `:nearest`, `:down`, `:up`, `:zero`. This is a Sollya symbolic
rounding operation, not a complete finite-exponent IEEE evaluator.
"""
function round_to(obj::SollyaObject, format; mode::Symbol = :nearest)
    modes = Dict(
        :nearest => :round_to_nearest,
        :down => :round_down,
        :up => :round_up,
        :zero => :round_towards_zero,
    )
    haskey(modes, mode) || throw(ArgumentError("unknown rounding mode: $mode"))
    _locked() do
        fmt = _format(format)
        try
            rnd = _indicator(modes[mode], values(modes))
            try
                return _ternary(:sollya_lib_round, obj, fmt, rnd)
            finally
                close(rnd)
            end
        finally
            close(fmt)
        end
    end
end
