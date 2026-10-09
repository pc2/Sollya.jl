# Contributing

Use a local development checkout and the system Sollya library; see the README.
Changes to the wrapper should include tests for the relevant native contract.
Keep the Julia dependencies minimal and compatible with Julia 1.10. Do not check
in a library binary, machine-specific path or package Manifest.toml.

Before changing a binding, consult the matching declaration in `sollya.h`, its
implementation in `sollya-library-wrappers.c`, its `doc/*.tex` entry and relevant
`tests-lib` cases. Use an explicit variadic signature for native variadic calls:
the arm64 ABI distinguishes optional arguments from fixed arguments.

## Local development and tests

Use the checkout directly with `julia --project=.`, or add it to another project
with `Pkg.develop(path="/absolute/path/to/Sollya.jl")`.

Run the package tests with multiple Julia threads and worker processes enabled:

```sh
julia --project=. --startup-file=no --threads=4 -e 'using Pkg; Pkg.test()'
```

For cached dependencies and registry metadata, an offline run is:

```sh
JULIA_PKG_OFFLINE=true JULIA_PKG_SERVER='' \
  julia --project=. --startup-file=no --threads=4 \
  -e 'using Pkg; Pkg.test(; allow_reresolve=false)'
```

The optional native regression runner compiles selected original C tests from a
local Sollya 8.0 source tree. Set `CC` to the desired C compiler:

```sh
julia --project=. test/upstream/run_native.jl ../sollya-8.0
```

The worker tests require localhost sockets. In a sandbox that forbids sockets,
`SOLLYA_TEST_WORKERS=false` explicitly skips those tests. Normal testing and CI
include them. Results and supported configurations are in
[docs/verification.md](docs/verification.md).

## Formatting

JuliaFormatter is pinned in `tools/format`, with four-space indentation and a
92-column margin. From the repository root:

```sh
julia --startup-file=no --project=tools/format -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=tools/format scripts/format.jl
julia --startup-file=no --project=tools/format scripts/format.jl --check
```

The command covers `src`, `scripts`, `test` and `examples`. `--check` reports
required formatting without writing files. For offline setup, reuse a resolved
formatter manifest and cached dependencies, with `Pkg.offline(true)` before
`Pkg.instantiate()`.

## Ownership and concurrency rules

- Every native call and symbol lookup requires the process-wide library lock.
- A returned native reference must be owned or cleared on every error path.
- Preserve Julia roots across foreign calls; never retain borrowed native
  pointers after their owning object is released.
- Use the copying native list constructor. Avoid the `build_list` APIs that
  consume references unless a separate ownership contract is implemented.
- Finalizers queue cleanup; they must not call the native library or wait for
  a task lock. Free native GMP storage with the native GMP used by Sollya.
- Transfer plain data to workers. Native handles must not be serialized.
- Keep proof APIs separate from diagnostic estimates. Do not silently substitute
  sampling for a failed certificate.

Exact conversion uses `sollya_lib_get_constant_as_mpq` with a native-owned GMP
rational. Resolve GMP operations through the loaded Sollya library and clear
storage with that same GMP. Julia's GMP/MPFR objects must not cross that ABI
boundary. The internal structs mirror GMP's public `mpz_t`/`mpq_t` layout.
Diagnostic callbacks and native message storage also require the library lock;
preserve and restore existing callback and verbosity state on every exit.

When adding native test fixtures, record their source and preserve attribution.
Test Julia 1.10 and 1.13 on Linux and macOS through CI. New platform claims
require a native ABI test on that platform.

## Package metadata and publication

The package identity is `Sollya`, UUID `4ba3657f-7d7c-4d39-81ac-6271ee86fac5`,
with initial version `0.1.0`. Keep this UUID when publishing. The root project
contains runtime dependencies and the test target; formatter dependencies stay
in `tools/format`. Do not commit a package Manifest.toml.

Git installation is documented in the README; package registration is deferred.
The workflow in `.github/workflows` tests Julia 1.10 and 1.13 on Linux and macOS
on pushes, pull requests and manual dispatch. Record tested versions and platforms
in `docs/verification.md`. Preserve the MIT copyright and third-party notices.

Development of the wrapper, tests and documentation used OpenAI Codex assistance.
