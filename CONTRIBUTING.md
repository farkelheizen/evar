# Contributing

Keep the reference implementation as a single self-contained Zsh executable
using standard macOS tools. The registry is for non-secret values and must
remain independent of `dsec` manifests and Keychain backends. The contract is
in [spec/SPEC.md](spec/SPEC.md); user-facing behavior is in
[README.md](README.md).

## Local checks

Run the same checks as CI:

```zsh
zsh -n evar
zsh -n tests/lib.zsh
zsh -n tests/test-cli.zsh
zsh -n tests/test-validation.zsh
git diff --check
zsh tests/test-cli.zsh
zsh tests/test-validation.zsh
```

Together the suites take about 15 seconds; the concurrency tests start many
short-lived processes.

## Tests

- **Isolation.** Every evar invocation goes through the helpers in
  `tests/lib.zsh`, which set an explicit temporary `EVAR_HOME` and `HOME`,
  refuse to run without `EVAR_HOME`, and run from a scratch working directory.
  Tests must never read or modify the user's real registry
  (`~/.config/evar`). Do not call `evar` directly from a test.
- **Synthetic values only.** Never put real credentials, personal
  configuration, or secrets in tests, fixtures, logs, or docs.
- **Function-level tests.** `evar` skips `main` when it is sourced, so tests can
  `source` it and call individual functions (`run_fn`, `run_snippet`). This is
  only for the test suites; the script is not meant to be sourced into an
  interactive shell.
- **Case sensitivity.** The suites must pass on case-insensitive (default
  APFS) and case-sensitive filesystems; tests that need one kind skip on the
  other. To exercise the case-sensitive paths, point `TMPDIR` at a
  case-sensitive volume, for example a throwaway disk image made with
  `hdiutil create -fs "Case-sensitive APFS" ...`, and run both suites there.
- **Permissions.** Failure-injection tests (`chmod`) skip when run as root.

## Invariants to preserve

- **No evaluation.** Stored values are data; never `eval`, `source`, or
  interpolate them into a command line. Print them with `emit`/`out`, not by
  hand.
- **Validate before side effects.** Scope, variable, and value are checked
  before the first directory or file is created.
- **Exact-case names, no symlinks.** Look entries up by listing the parent
  directory (`find_entry`), refuse symlinks and wrong file types (exit 3), and
  never treat an I/O error as "missing". A path that has truly vanished mid-walk
  is "missing".
- **Exit codes.** 0 success; 1 usage, invalid identifier, case conflict, or
  missing; 2 value validation; 3 filesystem. Diagnostics go to stderr as
  `evar: ...` and never contain stored values.
- **Atomic writes.** `mktemp` in the target directory, then `mv -f`; directories
  `0700`, files `0600`.
- **Functions that `exit`** (`fail`, `usage_fail`, `value_fail`, `io_fail`) must
  not run inside `$(...)` or the left side of a pipeline.

## Change guidelines

- Update inline help (`usage` and `usage_cmd` in `evar`), `README.md`,
  `SECURITY.md`, `spec/SPEC.md`, and tests together when behavior changes. Keep
  them in agreement, and clearly distinguish proposed features from implemented
  behavior.
- Add a failing test first for behavior changes and bug fixes, and check that it
  fails without the fix.
- Keep filesystem writes atomic and permission-conscious, and report errors
  explicitly.
- Do not bump `EVAR_VERSION` or tag a release for ordinary changes. A release
  makes the version in `evar` match the `vMAJOR.MINOR.PATCH` tag.
- Keep `docs_local/` private and untracked. Check `git status` before staging.

The intended license is MIT, but the license file and publication remain
approval-gated.
