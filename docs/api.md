# API and numerical contracts

## Native library and ownership

The initial binding targets the public `sollya.h` API in Sollya 8.0. Library
loading and initialization are lazy and protected by a process-wide reentrant
lock. No native handles are stored in precompile images. Returned references are
owned by `SollyaObject`; finalizers never enter the native library directly.

`with_objects() do keep ... end` provides explicit scoped cleanup. `keep(obj)`
registers an open local `SollyaObject` and returns the same object. Registered
objects are closed in reverse registration order when the callback returns or
throws. Register every temporary that needs deterministic cleanup, including
intermediate expressions; unregistered objects still rely on explicit `close`
or finalizers. Repeated registration and early `close` are safe. Register
`copy(obj)` to keep an existing object open. The callback's return value is
unchanged, so return Julia data or an unregistered copy to retain usable results.
The registrar rejects use after the scope exits or from another task; each task
can create its own scope. This helper does not hold the native lock across the
callback or change settings. Nest it inside `with_session` to scope settings too.

Sollya has no per-session context handle. `Session` stores plain Julia settings:
precision, verbosity, optional diagnostic sample count (`points`) and subdivision
threshold (`diameter`). Working precision must be at least 12 bits, Sollya's
native minimum. `with_session` saves these settings and restores them in
a `finally` block. Nested scopes work on one task. A session does not isolate the
Sollya symbol environment or make direct calls from other bindings thread safe.

`Session(; precision=precision(BigFloat), ...)` defaults to Julia's current BigFloat precision.
It captures that value at construction, so a stored or serialized session keeps
the same precision even if Julia's setting later changes. Pass `precision`
explicitly to override it. The 12-bit minimum applies to both the default and
explicit values. Constructing the session does not load Sollya or change
settings. `with_session() do ... end` constructs a session with these defaults
on entry. Julia's precision and rounding mode remain independent.

Exact conversion uses `sollya_lib_get_constant_as_mpq` with a native-owned GMP
rational. GMP operations are resolved through the loaded Sollya library and
cleared by that same GMP. Julia's GMP/MPFR objects never cross that ABI boundary.
The small internal structs mirror GMP's public `mpz_t`/`mpq_t` layout.

## Errors and diagnostics

`SollyaError` retains its `operation` and `detail` fields and adds `diagnostics`,
a vector of native message IDs paired with generic summary strings. The usual
two-argument constructor remains supported. `showerror` prints the summaries
after the main error. Parsing errors also include up to 256 characters of the
input, quoted and escaped.

Parsing, `fpminimax`, `remez` and `supnorm` collect up to 16 distinct recent native
messages for the failing call. These are Sollya's generic summaries, not its
fully formatted console messages. Explicitly suppressed messages remain
unavailable, and a failure can have no diagnostics. Successful-call diagnostics
are discarded. Errors and their diagnostics are plain data suitable for workers.

With verbosity zero and no existing callback, the approximation routines briefly
enable warning capture while keeping console output quiet, then restore verbosity
and the native callback on every exit. Parsing keeps verbosity unchanged because
expressions can read settings; its native diagnostics depend on that verbosity.
An existing callback is forwarded to and restored, with its original verbosity
filtering and display decisions preserved. Callback state and native message
storage remain within the process library lock.

## Expressions and data transfer

- `sollya(text)`, `sollya"…"`, `SollyaObject(text)` and
  `parse(SollyaObject, text)` parse an expression and reject native errors.
- `SollyaObject(integer/rational/binary_float)` imports the stored value exactly.
  `BigFloat` is converted through its exact dyadic rational, independently of
  Julia's current precision and rounding mode. This also applies to BigFloat
  endpoints and accuracy in `ApproximationRequest`; conversion does not change
  those settings. Signed zero is not a distinct rational coefficient; model IEEE
  sign semantics in the evaluator.
- `SollyaObject(π)`, `SollyaObject(ℯ)` and `SollyaObject(Base.MathConstants.φ)`
  import exact symbolic constants: `pi`, `exp(1)` and `(1 + sqrt(5)) / 2`.
  The aliases `pi`, `Base.MathConstants.e` and `Base.MathConstants.golden` also
  work. No floating-point rounding occurs during construction; the constants
  are evaluated at the precision of use. Mixed arithmetic such as `π * x`,
  `ℯ * x` and `x + Base.MathConstants.φ` uses these exact imports.
  Use `SollyaObject(π) / 2` to keep a fraction symbolic: Julia evaluates `π / 2`
  as floating point before it can be imported. Likewise, use
  `exp(SollyaObject(1))` instead of `SollyaObject(exp(1))` to preserve symbolic ℯ.
  `interval(0, π)` evaluates and rounds its endpoints outward at the current
  Sollya working precision, as do intervals with ℯ or φ endpoints.
  Other Julia irrational constants, including Euler's constant `γ` and Catalan's
  constant, are not imported implicitly. `ApproximationRequest`
  endpoints still require finite rational or binary floating-point values.
- `exact_rational(obj)` returns `Rational{BigInt}` only if Sollya proves the object
  is a finite rational constant. It rejects irrational constants and intervals.
- `zero(SollyaObject)` and `one(SollyaObject)` construct exact scalar identities.
  The instance forms `zero(obj)` and `one(obj)` return scalar identities for
  constants and expressions, and singleton interval identities for intervals.
  They reject lists, other nonnumeric objects and closed handles with
  `ArgumentError`. Each call returns a new owning object; closing an identity
  does not close its input or another identity.
- `coefficients(p)` returns a `Vector{Rational{BigInt}}` in ascending order, including
  absent internal terms. `coeff(p,k)` uses **zero-based polynomial order**.
  Unlike native Sollya's `coeff`, both reject a non-polynomial.
- `coefficients(BigFloat, p, mode=rounding(BigFloat); precision=precision(BigFloat),
  max_work_precision=nothing)`
  returns a `Vector{BigFloat}` in the same order, including zeros. Each finite
  real coefficient, including symbolic values such as π and sqrt(2), is
  correctly rounded using `BigFloat(c, mode; precision, max_work_precision)`.
  The refinement limit applies independently to each coefficient, with the same
  default as scalar conversion. Julia's settings are unchanged, and temporary
  Sollya settings are restored on success or failure. Non-polynomials,
  non-finite coefficients and uncertifiable rounding raise `SollyaError`; no
  partial vector is returned. `coefficients(p)` still requires rational values.
  Rounding can change the polynomial: a certificate for `p` does not
  automatically apply to its rounded coefficients.
- `expression(obj; display=:dyadic)` prints stored binary constants exactly and
  restores the display setting. This is an expression representation, not a
  proof that arbitrary irrational expressions are rational.
- `Float64(obj)` is approximate. Do not use it to export a certified upper bound:
  it may round inward. Use exact `bounds(obj)` or outward-rounded
  `bounds(BigFloat, obj; precision=...)`.
- `BigFloat(obj, mode=rounding(BigFloat); precision=precision(BigFloat),
  max_work_precision=nothing)` correctly rounds a finite real constant.
  Rational constants use
  [MPFR's rational conversion](https://www.mpfr.org/mpfr-current/mpfr.html#Assignment-Functions).
  Supported modes are `RoundNearest` (ties to even), `RoundDown`, `RoundUp`,
  `RoundToZero` and `RoundFromZero`. Other constant expressions, including π, ℯ,
  φ, `sqrt(2)` and `log(2)`, use guaranteed interval enclosures at increasing
  working precision. A result is returned only when both endpoints round to
  the same BigFloat under the requested mode. `convert(BigFloat, obj)` and
  `BigFloat.(objects)` use Julia's current settings.
  `max_work_precision` defaults to `max(4096, 2 * precision)`, capped at
  `typemax(Cint)`; an explicit value must be in `12:typemax(Cint)`. It limits
  refinement's Sollya working precision, not native guard bits or elapsed time,
  and does not restrict exact rational conversion. If the limit is reached
  without certifying rounding, conversion throws `SollyaError`. Increase the
  limit to retry a difficult expression. Exact zeros or rounding-boundary
  values that Sollya cannot simplify may remain inconclusive at any precision.
  Nonconstant functions, intervals, infinities and NaN are rejected. Julia's
  settings are unchanged, and temporary Sollya settings are restored on success
  and failure. `exact_rational` and `coefficients(p)` continue to require
  rational values.
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
SpecialFunctions.jl.

`equal(a, b)` returns Sollya's native `==` result, which is not a certified
mathematical equality test. A `false` result can mean equality was not
established, even for matching expressions involving π. A `true` result can
rely on numerical evaluation that did not prove equality. Native precision and
simplification settings affect the result, and warnings may be hidden at
verbosity zero. Only non-Boolean native results raise `SollyaError`.

`structurally_equal(a, b)` compares stored native representations without
numerically testing equality. Use it to recognize matching symbolic expressions,
including independently constructed `π * x` objects. Construction and
simplification can affect the stored structure; this is not a comparison of the
original source text. Different structures may still represent the same
mathematical function, and two native NaNs compare structurally equal. Both
comparison functions import non-object arguments through `SollyaObject`.
Julia object identity, `isequal`, and hashing are not repurposed.

## Approximation

`approximate(function_expr, (lower, upper); kwargs...)` generates and certifies a
polynomial directly from an expression string and finite real endpoints,
including BigFloat values. It returns an `ApproximationResult` containing exact
coefficients, the actual certified domain and the norm enclosure. It uses the
same validation, keywords and defaults as `ApproximationRequest`: `basis=5`,
`formats=:single`, `error=:absolute`, `arithmetic=:floating`,
`precision=precision(BigFloat)`, and `accuracy=1//1024`. Precision is captured
when constructing the request, including for later execution on workers; an
explicit `precision` overrides this default. The minimum is 12 bits.
Endpoint values are preserved exactly before any outward
rounding by interval construction. Settings are restored and temporary native
objects are released on both success and failure. For stored jobs or a process
pool, construct an `ApproximationRequest` and call `approximate(request)` or
`approximate_many(pool, requests)`.

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

`evaluate(BigFloat, f, point, mode=rounding(BigFloat);
precision=precision(BigFloat), max_work_precision=nothing)` substitutes the point
symbolically and then correctly rounds the resulting finite real constant.
For example, `evaluate(BigFloat, f, π; precision=512)` substitutes exact π;
a BigFloat point retains its stored value even if Julia's current precision is
lower. The requested output precision is independent of Sollya's current working
precision. Rounding modes and the refinement limit follow `BigFloat(obj; ...)`.
Use this overload when you need a correctly rounded reference:
`BigFloat(evaluate(f, point))` converts an already approximated native value and
cannot recover lost accuracy.

This overload follows `substitute` semantics: scalar expressions are accepted
when their composition with `f` produces a constant. Intervals and non-scalar
objects are rejected, and nonconstant, non-finite or uncertifiable results throw
`SollyaError`. Input objects remain open, temporary objects are closed on success
or failure, Julia's settings are unchanged, and temporary Sollya settings are
restored.

`bounds(BigFloat, I; precision=precision(BigFloat))` exports a finite interval as
a pair of BigFloat endpoints, rounding the lower endpoint down and the upper
endpoint up. Both endpoints have the requested precision, so the result encloses
the stored interval even when reducing precision. Julia's rounding mode does not
affect this conversion, and neither Julia nor Sollya settings change. As with
exact `bounds(I)`, non-interval inputs throw `ArgumentError`, and infinite or NaN
endpoints throw `SollyaError`.

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
