# Sollya.jl

Julia bindings for [Sollya](https://www.sollya.org/): polynomial approximation,
symbolic expressions, interval evaluation and correctly rounded BigFloat values.

Uses an installed **Sollya 8.0** library and Julia standard libraries only.

## Installation

Requires **Julia 1.10 or later**. Install Sollya with your system package manager:

| Platform | Command |
| --- | --- |
| macOS | `brew install sollya` |
| Debian / Ubuntu | `sudo apt-get install sollya libsollya-dev` |

Install the unregistered Julia package directly from Git:

```julia
using Pkg
Pkg.add(url="git@github.com:pc2/Sollya.jl.git")
```

The Git URL uses SSH access. Set `JULIA_PKG_USE_CLI_GIT=true` before starting Julia
to use the system Git and its SSH configuration.

For a custom native installation, set `SOLLYA_LIBRARY` to the shared library's
path before the first numerical call.

## Quick start: polynomial approximation

```julia
using Sollya

result = approximate("erf(x)", (0, 1//4);
    basis=5, formats=:single, precision=256)

result.coefficients  # exact Rational{BigInt} values, ascending powers of x
result.norm_bound    # lower and upper bounds on absolute approximation error
result.polynomial    # stored polynomial as a Sollya expression
```

The bound certifies the **mathematical polynomial**. Rounding when evaluating
that polynomial requires additional error analysis.

## Expressions and BigFloat evaluation

```julia
with_objects() do keep
    f = keep(sollya"sin(x)+exp(x)")
    println(evaluate(BigFloat, f, 1//2; precision=256))
end
```

Expressions can contain symbolic constants such as π. `BigFloat(obj; precision=256)`
and `evaluate(BigFloat, ...)` return correctly rounded finite values.
`bounds(BigFloat, interval; precision=256)` rounds interval endpoints outward.
Unresolved rounding raises `SollyaError`.

Approximation requests and BigFloat conversions default to Julia's current
BigFloat precision. Use
`with_session(Session(; precision=512)) do ... end` to scope Sollya settings.

`with_objects` closes registered objects when the block exits. Return Julia data
or an unregistered `copy(obj)` to retain results. See
[object lifetime and settings](docs/api.md#library-object-lifetime-and-session-settings).

## Concurrent approximation jobs

```julia
requests = [ApproximationRequest("erf(x)", (0, 1//4); precision=bits)
            for bits in (128, 256, 384)]

results = SollyaPool(2) do pool
    approximate_many(pool, requests)
end
```

Each worker is an independent Julia process. Results preserve input order, and
failed jobs raise exceptions.

Calls within one process are serialized. The pool requires localhost sockets
and has no timeout or automatic retry. See [process pools](docs/api.md#process-pool).

## Documentation

- [API reference](docs/api.md): functions, formats, rounding, errors and proof behavior.
- [Verification](docs/verification.md): tested Julia versions and platforms.
- [Contributing](CONTRIBUTING.md): development, testing and formatting.

Exported functions also have Julia help entries: `?approximate`, for example.

## License

The wrapper is [MIT licensed](LICENSE), copyright Gerrit Pape.
Sollya and adapted test fixtures retain their upstream license:
[attribution](test/upstream/NOTICE.md), [license](test/upstream/COPYING).
