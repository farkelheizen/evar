# Project instructions

## Project shape

- Keep `evar` a self-contained Zsh script with macOS tools as its only runtime
  dependencies.
- Treat the registry as non-secret data, not a Keychain or secret manager.
  Store values as data and never evaluate registry contents as shell code
  (no `eval`, `source`, or putting a stored value on a command line).
- Follow the CLI parsing, error-reporting, and completion patterns of sibling
  projects. Update inline help (`usage`/`usage_cmd` in `evar`), `README.md`,
  `SECURITY.md`, and `spec/SPEC.md` together when command behavior or options
  change.
- Keep changes focused. Do not silently change existing command behavior or
  compatibility; add or update tests for behavior changes.

## Versioning and releases

- Use Semantic Versioning (`MAJOR.MINOR.PATCH`) for releases: patch for
  backward-compatible fixes, minor for backward-compatible features, and
  major for incompatible CLI changes.
- Before `1.0.0`, minor releases may also contain incompatible CLI changes;
  document them clearly. Apply the compatibility guarantees above starting
  with `1.0.0`.
- Keep the authoritative version in `evar` and expose it with `evar --version`.
  When cutting a release, make the version reported by the script match the
  Git tag `vMAJOR.MINOR.PATCH`.
- Do not bump the release version or create a release tag for ordinary
  unreleased changes.
- Before tagging, run the relevant checks, review user-facing documentation,
  and ensure the release notes accurately describe compatibility and security
  implications.

## Plans and documentation

- Put substantial or design-dependent work plans in the ignored `docs_local/`
  directory. Use a focused filename such as `feature-name-plan.md`; record
  decisions, proposed behavior, implementation steps, and validation.
- Use `docs_local/` for planning, not as a substitute for durable project
  documentation. Move finalized user-facing behavior and contributor guidance
  into `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, or `spec/SPEC.md` as
  appropriate.
- Treat local plans as private working material: do not stage or commit them,
  and never put secrets or sensitive user data in them.

## Validation and safety

- Run all of these for CLI changes, and keep them passing:
  `zsh -n evar`, `zsh -n tests/lib.zsh`, `zsh -n tests/test-cli.zsh`,
  `zsh -n tests/test-validation.zsh`, `git diff --check`,
  `zsh tests/test-cli.zsh`, and `zsh tests/test-validation.zsh`.
- Tests use only an isolated temporary registry through the helpers in
  `tests/lib.zsh` (explicit `EVAR_HOME` and `HOME`); never read or modify the
  user's real registry (`~/.config/evar`). The suites must pass on both
  case-insensitive and case-sensitive filesystems.
- Use synthetic values only. Never put real passwords, tokens, private keys,
  or other secrets in tests, fixtures, logs, examples, or documentation.
- Preserve these invariants:
  - Exit codes: 0 success; 1 usage, invalid identifier, case conflict, or
    missing scope/variable; 2 value validation (NUL, line break, invalid
    UTF-8); 3 filesystem/I/O, symlink, or wrong file type. Diagnostics go to
    stderr as `evar: ...` and never contain stored values.
  - Exact-case names on every OS; symlinks and wrong file types in the
    registry are exit 3 and never followed; an I/O error is never "missing".
  - Validate everything before the first filesystem change; writes are atomic
    (`mktemp` in the target directory, then `mv -f`), directories `0700`,
    files `0600`.
  - Functions that `exit` (`fail`, `usage_fail`, `value_fail`, `io_fail`) must
    not run inside `$(...)` or the left side of a pipeline.
- Document security-relevant limitations and exposure risks honestly. Do not
  claim Keychain behavior, locking, or race-free path handling that `evar`
  does not provide.
- Do not add runtime dependencies or broaden the project beyond the requested
  change.
