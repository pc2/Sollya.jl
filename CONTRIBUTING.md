# Contributing

Use a local development checkout and the system Sollya library; see the README.
Changes to the wrapper should include tests for the relevant native contract.
Keep the Julia dependencies minimal and compatible with Julia 1.10. Do not check
in a library binary, machine-specific path or package Manifest.toml.

Before changing a binding, consult the matching declaration in `sollya.h`, its
implementation in `sollya-library-wrappers.c`, its `doc/*.tex` entry and relevant
`tests-lib` cases. Use an explicit variadic signature for native variadic calls:
the arm64 ABI distinguishes optional arguments from fixed arguments.

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

Run `Pkg.test()` with multiple Julia threads and worker tests enabled. When adding
native test fixtures, record their source and preserve applicable attribution.
Test Julia 1.10 and current stable Julia on Linux and macOS through CI. New
platform claims require a native ABI test on that platform.
