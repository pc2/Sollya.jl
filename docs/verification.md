# Local verification

Verified on 4 October 2026 in `/Users/papeg/presage/Sollya.jl`.

| Component | Local configuration |
| --- | --- |
| Platform | macOS, Apple Silicon |
| Julia | 1.13.1 |
| Native library | Sollya 8.0, Homebrew `8.0_3` |
| C regression compiler | Homebrew LLVM/Clang 23.1.2 |
| Julia dependencies | `Distributed`, `Libdl`, `Serialization`, test-only `Test` |

## Results

- **863/863 Julia package checks passed** through `Pkg.test`, with four Julia
  threads and two independent local Julia worker processes. No tests skipped.
- **4/4 original Sollya C regression programs passed** against their supplied
  `.reference` files: `tcoeff`, `tfpminimax`, `tget_constant_as_uint64_array`,
  `tget_element_in_list`. Normalization covers whitespace and free-variable name.
- Package precompilation succeeded. Missing-library behavior was checked in a
  fresh process: import succeeds and the first native operation gives a useful
  error. Native handles are not retained in the precompile image.
- Exact rational transfer includes 2000-bit integers, 400-bit dyadic offsets,
  rationals, binary floating point inputs and a 512-bit Julia BigFloat input.
- Scoped settings restore after success, nested calls and exceptions. Native
  minimums of 12 precision bits and 3 diagnostic sample points are enforced.
- Parallel requests use differing working precisions; a failed request propagates
  and workers remain usable. Workers are removed by explicit and do-block cleanup.

## Reproduction

From the package directory, with the installed native dependencies:

```sh
JULIA_DEPOT_PATH=/tmp/presage-sollya-depot: \
JULIA_PKG_OFFLINE=true JULIA_PKG_SERVER='' \
  julia --startup-file=no --threads=4 --project=. \
  -e 'using Pkg; Pkg.test(; allow_reresolve=false)'

JULIA_DEPOT_PATH=/tmp/presage-sollya-depot: \
CC=/opt/homebrew/opt/llvm/bin/clang \
  julia --startup-file=no --project=. \
  test/upstream/run_native.jl ../sollya-8.0
```

The temporary depot keeps package caches outside the user's existing Julia depot.
The worker tests needed permission to bind localhost sockets in this execution
sandbox. Neither command downloaded dependencies or queried online resources.

## Scope of the evidence

The native proof routines certify polynomial approximation bounds under Sollya's
assumptions. The tests additionally check contract handling and selected numerical
results; they do not establish correctness of a future PRESAGe arithmetic IR or
generated evaluator. Linux and Julia 1.10 are configured in CI but have not been
executed in this local verification. No FPGA or vendor synthesis tools were used.
