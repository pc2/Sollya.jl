# Verification

## Tested configurations

The package tests pass for the following configurations of numerical
implementation `750bc95`. The [CI run on 9 October 2026](https://github.com/pc2/Sollya.jl/actions/runs/37980294936)
completed successfully in all four jobs, including thread and worker tests.

| Platform | Julia | Sollya | Passed checks |
| --- | --- | --- | --- |
| Ubuntu, x86-64 | 1.10.12 | 8.0, distribution package | 1,521 |
| Ubuntu, x86-64 | 1.13.1 | 8.0, distribution package | 2,121 |
| macOS, Apple Silicon | 1.10.12 | 8.0, Homebrew | 1,521 |
| macOS, Apple Silicon | 1.13.1 | 8.0, Homebrew | 2,121 |

The earlier CI selector `'1'` resolved to Julia 1.13.1 in that run. The workflow
now names `'1.13'` explicitly alongside `'1.10'`. Test counts differ between Julia
versions as reported by their test runners. Windows support is not established.

## What the tests cover

- Exact import and export of integers, rational values and stored BigFloat values,
  including values wider than machine precision.
- Correctly rounded BigFloat conversion, point evaluation and coefficient export
  for rational and symbolic constants, with all five supported rounding modes.
- Outward interval bounds and restoration of Julia and Sollya settings.
- Approximation and certified norm APIs, adapted upstream regression cases,
  error diagnostics and explicit refinement failures.
- Scoped object cleanup, copying, broadcasting and rejection of native-object
  serialization.
- Thread serialization and independent worker processes, including recovery after
  numerical failures and worker cleanup.

Four original Sollya C regression programs also passed locally on 6 October
2026 with Clang 23.1.2: `tcoeff`, `tfpminimax`,
`tget_constant_as_uint64_array` and `tget_element_in_list`.

## Git installation and PRESAGe integration

On 9 October 2026, a fresh temporary PRESAGe project installed Sollya directly
from its Git remote at commit `750bc95613f2742e54eb12f3858b1c6dbbc73c6d`.
It precompiled and passed all 2,121 Sollya checks on Julia 1.13.1 without using
a sibling development checkout.

That installation also passed concurrent LUT/polynomial generation, certificate
replay, and generated AP/AC kernel compilation and sampled verification through
PRESAGe's standalone C++ checker. Setup checks covered an explicit local checkout
override and restoration of the pinned Git dependency from an existing local
Manifest. These integration checks ran on macOS with the public vendor headers.

Import and precompilation without a discoverable native library were checked
locally: loading the Julia module succeeds, and the first numerical operation
reports how to install or locate Sollya.

## Scope

Sollya's proof routines retain their native mathematical assumptions. Their norm
bounds apply to mathematical expressions and polynomials; an application's
rounded arithmetic needs its own error analysis.

Symbolic refinement can remain inconclusive at exact rounding boundaries.
`max_work_precision` limits precision, rather than runtime; some native calls can
take a long time. See the [API reference](api.md) for conversion and proof behavior.

Development and test commands are in [CONTRIBUTING.md](../CONTRIBUTING.md).
