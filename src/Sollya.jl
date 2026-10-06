"""
Managed Sollya 8.0 bindings for polynomial approximation, exact coefficient
transfer, interval evaluation and certified error bounds. Native calls are
serialized within each process; `SollyaPool` provides process concurrency.
"""
module Sollya

using Libdl
import Distributed
import Serialization

export SollyaObject,
    SollyaError,
    Session,
    with_session,
    with_objects,
    working_precision,
    sollya,
    @sollya_str,
    variable,
    interval,
    sollya_list,
    expression,
    isfunction,
    isrange,
    islist,
    equal,
    exact_rational,
    coefficients,
    infimum,
    supremum,
    midpoint,
    bounds,
    evaluate,
    enclosure,
    differentiate,
    substitute,
    horner,
    canonical,
    expand,
    simplify,
    degree,
    coeff,
    erf,
    erfc,
    fpminimax,
    remez,
    supnorm,
    infnorm,
    dirtyinfnorm,
    checkinfnorm,
    guessdegree,
    findzeros,
    dirtyfindzeros,
    round_to,
    library_path,
    drain_finalizers!,
    ApproximationRequest,
    ApproximationResult,
    approximate,
    SollyaPool,
    approximate_many

include("library.jl")
include("objects.jl")
include("diagnostics.jl")
include("session.jl")
include("functions.jl")
include("approximation.jl")
include("workers.jl")

end
