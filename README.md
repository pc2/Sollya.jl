# Sollya.jl

Julia bindings for [Sollya](https://www.sollya.org/): polynomial approximation,
symbolic expressions, BigFloat conversion and certified approximation bounds.
The package uses the installed **Sollya 8.0** shared library and Julia standard
libraries only. It does not download or build native dependencies on import.

## Installation

Requires Julia 1.10 or later and an installed Sollya 8.0 shared library.
Package tests pass on Linux and macOS; see the
[verification results](docs/verification.md). Windows support is not established.

Install the native dependency on macOS with `brew install sollya`, or on
Debian/Ubuntu with `sudo apt-get install sollya libsollya-dev`. For other systems,
see the [Sollya installation instructions](https://www.sollya.org/).

This package is not registered. Install it directly from its Git repository:

```julia
using Pkg
Pkg.add(url="git@github.com:pc2/Sollya.jl.git")
using Sollya
```

This URL uses GitHub SSH access. Set `JULIA_PKG_USE_CLI_GIT=true` before starting
Julia to use the system Git and its existing SSH configuration. To install a
specific revision, pass a commit or tag as `rev` to `Pkg.add`.

`SOLLYA_LIBRARY` is optional when the library is discoverable through the system
loader or the usual Homebrew locations. Set it before the first Sollya operation;
`library_path()` returns the actual loaded file. A missing library fails on first
use, with an installation message, rather than during package precompilation.

## Generate and certify a polynomial

```julia
using Sollya

result = approximate("erf(x)", (0, 1//4);
    basis=5, formats=:single, precision=256)

result.coefficients  # Rational{BigInt}, ascending powers of x
result.norm_bound    # exact lower and upper bounds on approximation error
result.polynomial    # dyadic Sollya expression
```

The endpoint tuple also accepts BigFloat values. For stored jobs or a process
pool, construct an `ApproximationRequest` and use `approximate(request)` or
`approximate_many(pool, requests)`.

The degree-five example gives an absolute approximation error bounded by about
`2.956e-9` with the installed Sollya 8.0 library. Its coefficients and bound may
vary with the working precision and native build. The returned bounds certify
the **mathematical polynomial**. Rounding and transformations in an implementation
of that polynomial require additional error analysis.

## Expressions, intervals and precision

```julia
with_session(Session(precision=256)) do
    with_objects() do keep
        f = keep(sollya"erf(x)")
        domain = keep(interval(0, 1//4))
        p = keep(fpminimax(f, 5, :single, domain; error=:absolute))
        certificate = keep(supnorm(p, f, domain; accuracy=1//1024))
        println(coefficients(p))
        println(coefficients(BigFloat, p; precision=256))
        println(bounds(certificate))
        println(bounds(BigFloat, certificate; precision=256))
    end
end
```

`Session()` and `ApproximationRequest` capture Julia's current BigFloat precision
by default. This also sets the default for `with_session()` and direct
`approximate(...)` calls. Pass `precision=512`, for example, to override it.
Stored sessions and requests retain their captured precision even if Julia's
setting later changes. Precision must be at least 12 bits. These APIs do not
change Julia's precision or rounding mode.

Arithmetic creates new `SollyaObject` values. `with_objects` closes every object
passed to `keep`, even if the block throws; register intermediate results too,
such as `keep(keep(x + 1) * x)`. Return Julia data or an unregistered `copy(obj)`
to retain a result after the block. `close(obj)` releases an object explicitly
and is safe to call more than once. Scoped cleanup keeps memory bounded in long
computations.

## Functions covered

| Purpose | API |
| --- | --- |
| Expressions and exact constants | `sollya`, `sollya"…"`, `SollyaObject`, `zero`, `one`, `variable`, arithmetic, Julia elementary functions, `erf`, `erfc` |
| Polynomial operations | `differentiate`, `substitute`, `horner`, `canonical`, `expand`, `simplify`, `degree`, `coeff`, `coefficients` |
| Sollya lists | `sollya_list`, one-based indexing, iteration, `length` |
| Object lifetime | `with_objects`, `copy`, `close`, `isopen`, `drain_finalizers!` |
| Intervals and evaluation | `interval`, `infimum`, `supremum`, `midpoint`, `bounds`, `evaluate`, `enclosure` |
| Approximation | `remez`, `fpminimax`, `guessdegree` |
| Error analysis | `supnorm`, `infnorm`, `checkinfnorm`, diagnostic `dirtyinfnorm` |
| Zeros | `findzeros`, diagnostic `dirtyfindzeros` |
| Representation | `exact_rational`, `expression`, approximate `Float64`, rounded `BigFloat`, `round_to` |
| Configuration and concurrency | `Session`, `with_session`, `working_precision`, `SollyaPool`, `approximate_many` |

Failed parsing, `fpminimax`, `remez` and `supnorm` calls provide context through
`SollyaError`. Its `diagnostics` field holds available native message IDs and
summary strings, also shown in the printed error. See the
[diagnostic contract](docs/api.md#errors-and-diagnostics) for capture limits.

`SollyaObject(π)`, `SollyaObject(ℯ)` and `SollyaObject(Base.MathConstants.φ)` import
pi, Euler's number and the golden ratio symbolically. Their aliases `pi`,
`Base.MathConstants.e` and `Base.MathConstants.golden` also work. Mixed expressions
such as `π * x` or `ℯ * x` preserve these constants exactly; `interval(0, π)`
produces outward-rounded bounds at the current Sollya working precision.

`BigFloat(obj; precision=256)` correctly rounds finite symbolic constants as well
as rational values. For symbolic values, conversion refines an enclosure until
rounding is certified; `max_work_precision` controls the refinement limit.
An inconclusive conversion throws `SollyaError`. See the
[conversion contract](docs/api.md#expressions-and-data-transfer).

`coefficients(BigFloat, p; precision=256)` applies this conversion to every
coefficient, returning a Julia vector in ascending power order. Symbolic
coefficients are supported, and `max_work_precision` applies to each coefficient.

`evaluate(BigFloat, f, x; precision=256)` substitutes `x` exactly, then correctly
rounds the resulting constant. It accepts numeric and symbolic points, defaults
to Julia's BigFloat settings, and supports the same `max_work_precision` limit.

Use `structurally_equal(a, b)` to compare stored symbolic expressions. `equal(a, b)`
uses Sollya's native comparison, which is not a certified equality test; see the
[comparison contract](docs/api.md#expressions-and-data-transfer).

Symbolic composition and elementary functions can be parsed directly. The wrapper
does not expose user-defined native callbacks, external functions, plotting,
proof-file generation or arbitrary basis functions.

See the [API reference](docs/api.md) for formats, argument conventions
and numerical assumptions. Julia's help mode (`?function_name`) also provides
documentation for exported functions.

## Concurrent jobs

```julia
requests = [ApproximationRequest("erf(x)", (0, 1//4); precision=bits)
            for bits in (128, 256, 384)]

results = SollyaPool(2) do pool
    approximate_many(pool, requests)
end
```

Each worker is an independent Julia process with independent Sollya state.
Results preserve input order. A failed job raises an exception. The pool uses
Julia `Distributed`, which requires localhost socket access and the same native
library as the parent. It has no timeout, cancellation or automatic retry.

Within one process, calls are serialized across Julia threads. `with_session`
holds the lock for the entire callback and restores its settings after errors.
Waiting there for another task that needs Sollya in the same process can
deadlock. Separate worker processes provide concurrent numerical execution.

## License

The Julia wrapper is [MIT licensed](LICENSE), copyright Gerrit Pape.
The separately installed Sollya library and adapted regression fixtures retain
their upstream license. The fixtures include
[attribution](test/upstream/NOTICE.md) and the [license](test/upstream/COPYING).

Development, testing and formatting instructions are in
[CONTRIBUTING.md](CONTRIBUTING.md).
