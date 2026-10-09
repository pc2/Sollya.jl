# Changelog

## 0.1.0 — unreleased

- Initial managed Sollya 8.0 numerical bindings for PRESAGe.
- Exact rational coefficient transfer and guaranteed interval evaluation.
- Scoped settings, thread serialization and deferred native cleanup.
- Local process pool with serializable approximation requests and results.
- Local regression tests, adapted upstream cases and native test reuse.
- Exact import of stored BigFloat values regardless of ambient precision.
- Correctly rounded BigFloat conversion of rational and symbolic constants,
  polynomial coefficient export and point evaluation, with explicit rounding,
  precision and symbolic refinement limits.
- Outward-rounded BigFloat interval bounds.
- Symbolic imports of π, ℯ and φ, scalar and interval identities, and structural
  comparison distinct from native heuristic equality.
- Broadcasting for expressions and finite native lists, and `with_objects`
  for scoped ownership and cleanup.
- Direct `approximate(expression, (lower, upper); ...)` calls. Sessions and
  requests capture current BigFloat precision by default, with explicit overrides.
- Native diagnostic summaries in parsing and approximation errors.
- Correct optional seed placement in `fpminimax`, finite ordered request
  endpoints, and validation of approximation accuracy.
