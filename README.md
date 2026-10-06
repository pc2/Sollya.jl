# Sollya.jl

Julia bindings for the Sollya operations needed by PRESAGe: polynomial
approximation, exact coefficient transfer and certified approximation bounds.
The package uses the installed **Sollya 8.0** shared library and Julia standard
libraries only. It does not download or build native dependencies on import.

## Local setup

Julia 1.10 or later is the declared compatibility range. Local development has
been tested with Julia 1.13.1 and Homebrew Sollya 8.0 on Apple Silicon. Linux and
Julia 1.10 are included in CI; Windows support is not established.

From this directory:

```sh
export SOLLYA_LIBRARY=/opt/homebrew/opt/sollya/lib/libsollya.dylib
julia --project=. --startup-file=no
```

Then `using Sollya`. In another Julia project, use the standard development
workflow:

```julia
using Pkg
Pkg.develop(path="/absolute/path/to/Sollya.jl")
using Sollya
```

`SOLLYA_LIBRARY` is optional when the library is discoverable through the system
loader or the usual Homebrew locations. Set it before the first Sollya operation;
`library_path()` returns the actual loaded file. A missing library fails on first
use, with an installation message, rather than during package precompilation.

## Formatting

JuliaFormatter uses four-space indentation and a 92-column margin, matching
PRESAGe. Its version is pinned in a separate development environment. From the
repository root:

```sh
julia --startup-file=no --project=tools/format -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=tools/format scripts/format.jl
julia --startup-file=no --project=tools/format scripts/format.jl --check
```

The command formats Julia files in `src`, `scripts`, `test` and `examples`.
`--check` exits with status 1 when formatting is required and does not write
files. For offline setup, reuse a resolved formatter manifest and cached
dependencies, and call `Pkg.offline(true)` before `Pkg.instantiate()`.

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
the **mathematical polynomial**; evaluator rounding, input conversions, range
reduction and reconstruction need their own analysis in PRESAGe.

## Low-level numerical workflow

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

Native objects own their references. Arithmetic creates new objects; `copy`
creates an independent reference; `close` is idempotent. Finalizers queue cleanup
for the next serialized native call. `with_objects` closes every object passed
to `keep`, even if the block throws. Register intermediate results too, such as
`keep(keep(x + 1) * x)`. Return Julia data or an unregistered copy to retain a
result after the block. Use scoped or explicit cleanup for bounded memory in
long searches, and `drain_finalizers!()` after forced GC when needed. The shared
library stays initialized for the process lifetime, avoiding global shutdown
while references remain alive.

## Functions covered

| Purpose | API |
| --- | --- |
| Expressions and exact constants | `sollya`, `sollya"…"`, `SollyaObject`, `zero`, `one`, `variable`, arithmetic, Julia elementary functions, `erf`, `erfc` |
| Polynomial operations | `differentiate`, `substitute`, `horner`, `canonical`, `expand`, `simplify`, `degree`, `coeff`, `coefficients` |
| Native lists | `sollya_list`, one-based indexing, iteration, `length` |
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

This is a focused numerical interface, not a binding of the entire Sollya command
language. User-defined native callbacks, external functions, plotting, proof-file generation
and arbitrary basis functions are outside the initial API. Symbolic composition
and supported elementary functions can still be parsed directly.

See [API and numerical contracts](docs/api.md) for formats, argument conventions
and important native assumptions. All exported functions have Julia docstrings.

## Concurrent jobs

```julia
requests = [ApproximationRequest("erf(x)", (0, 1//4); precision=bits)
            for bits in (128, 256, 384)]

results = SollyaPool(2) do pool
    approximate_many(pool, requests)
end
```

Each worker is an independent Julia process with independent Sollya state.
Requests and results contain serializable data; raw native objects explicitly
reject serialization. Results preserve input order. Failure propagates as an
exception. The pool uses Julia `Distributed`, which requires localhost socket
access; it does not need internet access. Workers use this package's project and
the same resolved native library as the parent.

Within one process, calls are serialized across Julia threads. `with_session`
holds the lock for the entire callback and restores its settings after errors.
Never wait in that callback for another task that needs Sollya in the same
process. Calls made directly through another Sollya binding must use compatible
serialization; this package cannot coordinate unknown native callers.

## Test locally

```sh
julia --project=. --startup-file=no --threads=4 -e 'using Pkg; Pkg.test()'
```

For an offline installation with the standard libraries already available:

```sh
JULIA_PKG_OFFLINE=true JULIA_PKG_SERVER='' \
  julia --project=. --startup-file=no --threads=4 \
  -e 'using Pkg; Pkg.test(; allow_reresolve=false)'
```

Tests cover exact import/export beyond machine precision, ownership, error paths,
session restoration, proof contracts, thread serialization and two independent
worker processes. See [local verification results](docs/verification.md).
Several numerical fixtures are adapted from the supplied
Sollya 8.0 regression suite. [Their provenance](test/upstream/NOTICE.md) is kept
with the tests. The optional native test runner also compiles and runs selected
original C tests from a local Sollya source tree:

```sh
julia --project=. test/upstream/run_native.jl ../sollya-8.0
```

In a sandbox that forbids all socket creation, explicitly set
`SOLLYA_TEST_WORKERS=false` to skip the worker tests. This is a test-environment
switch; normal testing and CI include them.

## License

The original Julia wrapper is [MIT licensed](LICENSE). Adapted Sollya regression
fixtures retain the [upstream license and attribution](test/upstream/NOTICE.md).
Sollya and its native dependencies retain their respective licenses and are not
vendored into this package.
