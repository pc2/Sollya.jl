# API and numerical contracts

## Native library and ownership

The initial binding targets the public `sollya.h` API in Sollya 8.0. Library
loading and initialization are lazy and protected by a process-wide reentrant
lock. No native handles are stored in precompile images. Returned references are
owned by `SollyaObject`; finalizers never enter the native library directly.

Sollya has no per-session context handle. `Session` stores plain Julia settings:
precision, verbosity, optional diagnostic sample count (`points`) and subdivision
threshold (`diameter`). Working precision must be at least 12 bits, Sollya's
native minimum. `with_session` saves these settings and restores them in
a `finally` block. Nested scopes work on one task. A session does not isolate the
Sollya symbol environment or make direct calls from other bindings thread safe.

Exact conversion uses `sollya_lib_get_constant_as_mpq` with a native-owned GMP
rational. GMP operations are resolved through the loaded Sollya library and
cleared by that same GMP. Julia's GMP/MPFR objects never cross that ABI boundary.
The small internal structs mirror GMP's public `mpz_t`/`mpq_t` layout.

## Expressions and data transfer

- `sollya(text)`, `sollya"…"`, `SollyaObject(text)` and
  `parse(SollyaObject, text)` parse an expression and reject native errors.
- `SollyaObject(integer/rational/binary_float)` imports the stored value exactly.
  `BigFloat` is converted through its exact dyadic rational, independently of
  Julia's current precision and rounding mode. This also applies to BigFloat
  endpoints and accuracy in `ApproximationRequest`; conversion does not change
  those settings. Signed zero is not a distinct rational coefficient; model IEEE
  sign semantics in the evaluator.
- `exact_rational(obj)` returns `Rational{BigInt}` only if Sollya proves the object
  is a finite rational constant. It rejects irrational constants and intervals.
- `coefficients(p)` returns exact coefficients in ascending order, including
  absent internal terms. `coeff(p,k)` uses **zero-based polynomial order**.
  Unlike native Sollya's `coeff`, both reject a non-polynomial.
- `expression(obj; display=:dyadic)` prints stored binary constants exactly and
  restores the display setting. This is an expression representation, not a
  proof that arbitrary irrational expressions are rational.
- `Float64(obj)` is approximate. Do not use it to export a certified upper bound:
  it may round inward. Use `bounds` and retain its exact rational endpoints.
- Native list indices are translated to **one-based Julia indexing**; indexed
  elements own their references. Only finite lists have a finite `length`.
- Expressions, constants and intervals broadcast as scalars, so operations such
  as `x .+ BigFloat[1, 2]` and `evaluate.(f, points)` work directly. Finite native
  lists broadcast elementwise into Julia arrays; use `Ref(list)` to pass a whole
  list as a scalar argument.

All numerical operators create native objects. `+ - * / ^`, `abs`, `sqrt`, `exp`,
`log`, `log2`, `log10`, the trigonometric and hyperbolic families, `log1p`,
`expm1`, `ceil` and `floor` extend their Julia methods for `SollyaObject`.
`Sollya.erf` and `Sollya.erfc` build symbolic expressions without requiring
SpecialFunctions.jl. `equal` uses Sollya's mathematical comparison and rejects
undecidable results; Julia object identity and hashing are not repurposed.

## Approximation

`fpminimax(f, basis, formats, interval; error, arithmetic, constrained, minimax)`:

- `basis`: nonnegative degree or increasing vector of selected monomial orders.
- `formats`: one scalar format repeated for each selected coefficient, or a
  vector of exactly the required length.
- `error`: `:absolute` (wrapper default) or `:relative`.
- `arithmetic`: `:floating` (default) or `:fixed`.
- Floating integer formats specify **significand precision**, with no finite
  exponent limit. Supported symbols are `:halfprecision`, `:single`, `:double`,
  `:doubleextended`, `:quad`, `:double_double`, `:triple_double`.
- Fixed formats are integer **fractional widths**. Width `b` restricts a
  coefficient to multiples of `2^-b`. Negative fractional widths are allowed.
  This is not a total word width; integer range analysis comes later.
- `constrained` is a fixed polynomial part added to the selected terms.
- `minimax` supplies the optional final seed polynomial or coefficient list.

The wrapper deliberately defaults to absolute error; native Sollya's command
defaults to relative error. Pass the keyword explicitly in ported code.

`remez(f, basis, interval; weight, quality, stop_bounds)` minimizes
`sup(abs(p*weight-f))`. The default weight is one. For relative approximation of
`g`, call `remez(one, basis, interval; weight=one/g)` with a native constant `one`.
`guessdegree` returns the native degree **interval**, preserving uncertainty and
possible unbounded endpoints; it does not return a guessed integer as a proof.

Sollya's differentiability and basis assumptions remain applicable. Sparse odd
monomials on a symmetric interval can violate the Haar condition and fail native
Remez convergence. Symmetry reduction to a one-sided or transformed kernel belongs
in the approximation planner. The binding surfaces failures as `SollyaError`.

## Proof versus estimates

`supnorm(p,f,I; error=:absolute, accuracy=1//1024)` returns an interval enclosing
the supremum of `abs(p-f)`, or `abs(p/f-1)` for relative error. `accuracy` controls
relative tightness of that norm enclosure; it is **not an error budget**. Native
proof failure is an exception and never triggers `dirtyinfnorm` automatically.
Both `supnorm` and `ApproximationRequest` require finite accuracy strictly between
zero and one; invalid values throw `ArgumentError`. `supnorm` also accepts Sollya
constant objects and expression strings whose values can be proved to lie in
that interval.

`infnorm` preserves the older native certified algorithm. `checkinfnorm` returns
true when the strict bound is proved; false can mean either a violated bound or
an inconclusive proof. Keep `diameter` positive to avoid unbounded subdivision.
`dirtyinfnorm` and `dirtyfindzeros` are diagnostics, not certificates.
`findzeros` inherits Sollya's smoothness and zero-isolation assumptions; see the
local Sollya manual before using it as an exhaustive root certificate.

`evaluate(f, point)` uses native faithful evaluation at the working precision.
It may return a constant, an enclosure or NaN. `evaluate(f, interval)` produces
a guaranteed image enclosure. `enclosure(f, point)` forces the latter path with a
singleton interval. Non-dyadic endpoints may be enlarged outward at the current
precision; `bounds` exports the **actual stored** finite endpoints exactly.

`round_to(obj, bits_or_format; mode=:nearest)` supports `:nearest`, `:down`,
`:up` and `:zero`. Sollya's symbolic format rounding is not a complete model of
a generated evaluator's overflow, subnormal, special-value or FMA behavior.

## Process pool

`ApproximationRequest` and `ApproximationResult` contain plain data. `approximate`
scopes its precision, runs `fpminimax` then `supnorm`, exports exact coefficients
and endpoints, and closes native objects. Its result records the domain actually
certified, error mode and working precision.
Request domain endpoints must be finite and ordered; non-finite endpoints throw
`ArgumentError` before conversion or native computation.

`SollyaPool(n)` owns local Julia workers. `approximate_many` runs independent jobs
using `Distributed.pmap` with one request per batch. Exceptions propagate and
workers remain usable after a numerical failure. Use a do block to ensure worker
cleanup. This initial pool API has no timeout, cancellation or automatic retry;
set resource limits in the planner before scheduling large native searches.
