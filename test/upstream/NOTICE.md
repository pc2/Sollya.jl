# Upstream regression fixtures

`cases.jl` adapts numerical inputs and expected results from the supplied
**Sollya 8.0** source distribution:

- `tests-lib/tget_constant_as_mpq.c`: exact rational conversion at low precision.
- `tests-lib/tcoeff.c`: coefficients of factored and summed polynomials.
- `tests-lib/tfpminimax.c` and `.reference`: fixed coefficients, constrained
  monomials and an optional seed with double-double formats.
- `tests-lib/tcheckinfnorm.c`: proved and unproved bounds.
- `doc/supnorm.tex`: relative error across the removable zero in `expm1`.

The original Sollya project is the author of these cases. The source distribution
applies the CeCILL-C license in its `COPYING`; a verbatim copy accompanies these
fixtures. The Julia test harness adapts the cases to check exact mathematical
results and proof intervals instead of reproducing display-dependent text.
No Sollya implementation source is included in the wrapper.

The optional `run_native.jl` runner compiles original C tests directly from a
caller-supplied local source directory. Their sources and reference files remain
in that directory. Their native results are checked against upstream references.
