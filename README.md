# evar

`evar` (Environment Variable Registry) is a local-first Zsh CLI for storing and
retrieving **non-secret** environment variable values. The registry is a plain
directory tree you can inspect and edit by hand: one raw value per file,
organized as `<org>/<module>/<version>/<VAR>`. Values are data. `evar` never
evaluates a stored value as shell code, and no command emits shell syntax.

`evar` is a single self-contained Zsh script that targets macOS and uses only
the system Zsh and standard macOS command-line tools. It has no third-party
runtime dependencies and operates independently of `dsec`.

> **Status:** `0.1.0-dev`, not yet released. The CLI is pre-1.0, so a minor
> release may still change behavior. See [spec/SPEC.md](spec/SPEC.md) for the
> precise contract.

## Install

Requires macOS with the system Zsh (5.9) at `/bin/zsh`. Put the script on your
`PATH`:

```zsh
install -m 755 evar ~/.local/bin/evar   # or any directory on PATH
evar --version
```

You can also run it in place with `zsh ./evar ...`.

## Quick start

```zsh
evar set acme/app SERVER_PORT 8080          # default slot "_"
evar set acme/app/dev LOG_LEVEL debug       # "dev" scope
evar get acme/app SERVER_PORT               # prints 8080
evar list                                   # acme/app/_  acme/app/dev
evar list acme/app/dev                      # LOG_LEVEL=debug
evar unset acme/app/dev LOG_LEVEL

export PORT="$(evar get acme/app SERVER_PORT)"
printf '%s\n' "$value" | evar set acme/app GREETING --stdin
```

## Commands

```
evar get    [-n|--no-newline] [--] <org>/<module>[/<version>] <VAR>
evar set    [--] <org>/<module>[/<version>] <VAR> <VALUE>
evar set    <org>/<module>[/<version>] <VAR> --stdin
evar unset  [-f|--force] [--] <org>/<module>[/<version>] <VAR>
evar exists [--] <org>/<module>[/<version>] [<VAR>]
evar list   [--] [<org>[/<module>[/<version>]]]
evar help | -h | --help          evar --version | -V
```

- **`get`** prints the value and a newline (`-n` omits the newline).
- **`set`** stores a single-line value, replacing any existing one, and prints
  nothing. `--stdin` reads exactly one line (ended by LF, CRLF, or end of
  input); a lone newline stores an empty value, while zero bytes or more than
  one line is rejected rather than truncated. Options may appear anywhere
  before `--`, so a value that begins with `-` needs it:
  `evar set -- acme/app NAME -v`.
- **`unset`** deletes a variable and prunes directories left empty. A missing
  variable is an error unless `-f` is given.
- **`exists`** is silent and answers with its exit status: with `<VAR>`, is
  that variable present; without it, does the scope hold at least one variable.
  It does not read values.
- **`list`** prints scopes (`org/module/version`, with an explicit `_` for the
  default slot) for no argument, `<org>`, or `<org>/<module>`, and
  `NAME=VALUE` lines for a full `<org>/<module>/<version>`. Scope lines sort
  bytewise as whole lines (like `LC_ALL=C sort`); variables sort by name.
  Nothing is printed if any entry is invalid. `list` with no argument succeeds
  with no output on an empty registry; an explicit argument that matches nothing
  exits 1.

Run `evar <command> --help` for per-command help.

## Scopes, versions, and the `_` slot

A scope is `<org>/<module>` or `<org>/<module>/<version>`. The third segment
is a qualifier: an environment (`dev`, `prod`), a version (`v1`), or a
combination (`v1-dev`). Omit it for the default slot `_`: `acme/app` and
`acme/app/_` are the same scope.

```
~/.config/evar/registry/
└── acme/
    ├── global/
    │   └── _/
    │       └── TZ                 ("UTC\n")
    └── app/
        ├── _/
        │   └── APP_NAME           ("app\n")
        ├── dev/
        │   ├── LOG_LEVEL          ("debug\n")
        │   └── SERVER_PORT        ("8080\n")
        └── prod/
            └── LOG_LEVEL          ("info\n")
```

## Names and values

| Element | Rule |
|---|---|
| `org`, `module` | 1-64 of `A-Z a-z 0-9 . _ -`, starting with a letter or digit, not ending in `.` |
| `version` | `_`, or the same rule as `org` |
| `VAR` | 1-128 of `A-Z a-z 0-9 _`, not starting with a digit |
| value | one line of valid UTF-8: no NUL, no CR or LF; empty is allowed |

- Windows device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`,
  `LPT1`-`LPT9`, case-insensitive, with or without an extension) are reserved
  in every name, and names may not end in `.`. These tighten the original
  design so a registry stays valid on Windows filesystems.
- Names are matched **exactly, including case, on every OS**. `Acme` and
  `acme` cannot coexist: `set` refuses a name that differs only by case from an
  existing one, and `get` of `ACME/app` reports that `acme` exists rather than
  silently succeeding on a case-insensitive disk.
- Spaces, `=`, quotes, `$`, backticks, glob characters, and Unicode are stored
  verbatim. A hand-edited file is read with every trailing CR/LF removed; a
  value that still contains a line break, NUL, or invalid UTF-8 is rejected.

## Registry location

The registry root is `$EVAR_HOME` if set, otherwise
`${XDG_CONFIG_HOME:-$HOME/.config}/evar/registry`. `EVAR_HOME` is the root
itself (`$EVAR_HOME/<org>/...`) and must be an absolute path; a relative path
is an error so the registry never lands in the working directory. The root is
created, mode `0700`, by the first `set`; read-only commands never create it.
The root must not be a symlink.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Usage error, invalid identifier, case conflict, or missing scope/variable |
| 2 | Invalid value (NUL, line break, invalid UTF-8) when writing, or a corrupt stored file when reading |
| 3 | Filesystem error: permission, disk full, a symlink or non-regular file in the registry, a failed write to standard output |

Diagnostics go to standard error as `evar: <message>`; standard output carries
only data. Diagnostics name scopes and variables but never print stored
values.

## Safety and limits

- Writes are atomic (a hidden temp file, then rename). Directories are created
  `0700` and value files `0600`.
- Symlinks and wrong file types inside the registry are refused (exit 3) and
  never followed. Only the root's last component is checked, not its ancestors.
- There is **no locking**: concurrent writers race and the last one wins, but a
  reader always sees a complete old or new value. A process killed with
  `SIGKILL` can leave a hidden `.evar-write.*` file, which `evar` ignores (it
  also keeps its directory from being pruned, as does a Finder `.DS_Store`).
- Any file or directory in the registry whose name looks like a valid
  identifier (for example a stray `README.md` at the root) must be the right
  type, or `list` fails with exit 3. Hidden and oddly named entries are
  ignored.
- Every `get`/`list` entry is validated with a few helper processes, which is
  fine for the small registries `evar` is built for.

See [SECURITY.md](SECURITY.md) for exposure risks.

## Relation to `dsec`

`evar` is intended to become the non-secret storage backend for
[`dsec`](https://github.com/farkelheizen/dsec), replacing `envc`: `dsec`
resolves a scope such as `acme/app/dev` and calls `evar get`/`exists`. `evar`
itself has no knowledge of `dsec` manifests or Keychain items, and `dsec`
integration lives in `dsec`.

## Not yet supported

Shell export emission (`evar export`), running a command with a scope injected
(`evar run`), layered fallback from a version to the `_` slot, shell
completions, and a plugin file.

## Security

Do not store passwords, tokens, private keys, or other secrets in `evar`.
Plaintext filesystem values are not a substitute for a secret manager, and
configuration values can still be sensitive. See [SECURITY.md](SECURITY.md)
for the trust boundaries and reporting guidance.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and contribution guidance.
Local planning material under `docs_local/` is intentionally ignored and must
not be committed. MIT licensing and publication remain approval-gated.
