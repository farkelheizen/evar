# evar specification

Status: describes the behavior implemented in `evar` `0.1.0-dev`. The CLI is
pre-1.0, so a minor release may still change behavior; changes are documented
in the release notes.

`evar` (Environment Variable Registry) stores **non-secret** environment
variable values in a local registry: one plain-text file per variable. A
value is data. `evar` never evaluates, sources, or expands a stored value, and
no `evar` command emits shell code.

## 1. Registry

### 1.1 Layout

```
<root>/<org>/<module>/<version>/<VAR>
```

- `<org>`, `<module>`, `<version>` are directories; `<VAR>` is a regular file
  whose content is the value followed by one `\n`.
- `<version>` is a general qualifier (an environment such as `dev`, a version
  such as `v1`, a combination such as `v1-dev`). When it is omitted, `evar`
  uses the reserved default slot `_`. `acme/app` and `acme/app/_` are the same
  scope; `_` is the normalized form in output.

### 1.2 Root

The registry root is the first of:

1. `$EVAR_HOME`, used as the root itself, when non-empty;
2. `$XDG_CONFIG_HOME/evar/registry`, when `XDG_CONFIG_HOME` is non-empty;
3. `$HOME/.config/evar/registry`.

The resulting path must be absolute (exit 1 otherwise, so the registry never
lands in the working directory); trailing slashes are removed and `/` itself is
rejected. A relative or unusable root is reported before any filesystem
change. The root is created (mode `0700`, with any missing parents) by the
first `set`; read commands never create it. An existing root is never
`chmod`-ed. The root itself must not be a symlink (exit 3); its ancestors may
be.

## 2. Names

| Element | Rule |
|---|---|
| `org`, `module` | `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$`, not ending in `.`, not a reserved device name |
| `version` | `_`, or the same rule as `org` |
| `VAR` | `^[a-zA-Z_][a-zA-Z0-9_]{0,127}$`, not a reserved device name |

Reserved device names are `CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, and
`LPT1`-`LPT9`, compared case-insensitively on the text before the first `.`
(so `con`, `CON.txt`, and `nul.tar.gz` are rejected; `COM10` and `console` are
valid).

A scope is `<org>/<module>[/<version>]`: two or three non-empty segments. For
`list` it is `<org>[/<module>[/<version>]]`: one to three. A leading, trailing,
or doubled `/`, more than three segments, or an invalid segment is a usage
error (exit 1) detected before any filesystem access.

Names are matched **exactly, including case, on every operating system**. A
path segment is located by listing its parent directory; an entry that differs
only by case counts as missing (and the error says so). `set` refuses (exit 1)
to create a scope segment or variable that differs only by case from an
existing sibling. This keeps a registry portable between case-insensitive
(macOS, Windows) and case-sensitive (Linux) filesystems.

## 3. Values

A value is a single line of valid UTF-8 text:

- valid UTF-8 (no overlong forms, no surrogates, nothing above U+10FFFF);
- no NUL byte;
- no `\n` or `\r`;
- empty is allowed.

Everything else, including leading and trailing spaces, `=`, quotes, `$`,
backticks, glob characters, tabs, and non-ASCII text, is stored and returned
verbatim.

Reading a stored file removes **every** trailing `\r` and `\n` (so a file
edited by hand in an editor works), then applies the rules above. Any `\r` or
`\n` remaining inside, a NUL, or invalid UTF-8 is exit 2; `evar` never
truncates or guesses.

## 4. Commands

```
evar get    [-n|--no-newline] [--] <org>/<module>[/<version>] <VAR>
evar set    [--] <org>/<module>[/<version>] <VAR> <VALUE>
evar set    <org>/<module>[/<version>] <VAR> --stdin
evar unset  [-f|--force] [--] <org>/<module>[/<version>] <VAR>
evar exists [--] <org>/<module>[/<version>] [<VAR>]
evar list   [--] [<org>[/<module>[/<version>]]]
evar help | -h | --help          evar --version | -V
```

With no arguments `evar` prints the help and exits 0. `--version` prints
`evar <version>`.

**Options** may appear anywhere before a literal `--`; everything after `--`
is positional. Unknown options, and options a command does not take, are exit
1. Short options cannot be combined. A value beginning with `-` needs `--`
(`evar set -- acme/app NAME -v`); a lone `-` is an ordinary value.
`-h`/`--help` after a command prints that command's help and exits 0.

**get** prints the value and a newline (no newline with `-n`). Exit 1 if the
scope or variable does not exist.

**set** stores the value, replacing any existing one. Validation of the scope,
variable, and value happens before anything is created. `<VALUE>` and
`--stdin` are mutually exclusive; a missing `<VALUE>` without `--stdin` is exit
1 (never an implicit empty value). With `--stdin`, exactly one line is read,
ended by `\n`, `\r\n`, or end of input; a lone newline is an empty value; zero
bytes, a second line, a bare `\r`, a NUL, or invalid UTF-8 is exit 2 (a closed
stdin is exit 3). It prints nothing on success.

**unset** deletes the variable, then removes the now-empty `<version>`,
`<module>`, and `<org>` directories, in that order, stopping at the first
directory that is not empty (hidden files such as `.DS_Store` count). The root
is never removed. A missing variable is exit 1, or exit 0 with `-f`. A corrupt
variable file can be deleted.

**exists** prints nothing and answers with its exit status. With `<VAR>`: 0 if
that variable file exists. Without it: 0 if the scope holds at least one
variable file. It does not read or validate values. Absence is exit 1; an
unsafe or unreadable entry is exit 3, never "absent".

**list**:

| Form | Output |
|---|---|
| `list` | every scope holding at least one variable, as `org/module/version` |
| `list <org>` | the same, for every module under `<org>` |
| `list <org>/<module>` | the same, for every version under it (not the variables) |
| `list <org>/<module>/<version>` | `NAME=VALUE`, one per variable |

Scopes always print in full with an explicit `_`, so the output can be fed to
other commands. The first `=` on a line separates the name (which cannot
contain `=`) from the value (which is single-line). `list` with no argument
exits 0 with no output on an empty or absent registry; an explicit argument
that matches nothing exits 1.

**Ordering.** Scope lines are sorted bytewise as whole strings (the order
`LC_ALL=C sort` produces: digits, then uppercase, then `_`, then lowercase;
`-` and `.` sort before `/`). `NAME=VALUE` lines are sorted bytewise by
variable name. Output is buffered: if any entry is invalid, nothing is
printed.

**Enumeration** considers only entries whose names match the grammar in
section 2. Other names (hidden files, `.DS_Store`, `*.tmp`, a leftover
`.evar-write.*` file, names with spaces) are ignored. An entry that matches
the grammar but is a symlink or the wrong file type is exit 3, even if valid
entries exist.

## 5. Exit codes and diagnostics

| Code | Meaning |
|---:|---|
| 0 | Success (including `unset -f` of a missing variable) |
| 1 | Usage error, invalid identifier, relative root, case conflict on `set`, or missing scope/variable |
| 2 | Value validation failure (NUL, line break, invalid UTF-8), on write or when reading a corrupt file; `--stdin` with zero bytes or more than one line |
| 3 | Filesystem or I/O failure: permission denied, disk full, rename failure, a symlink or non-regular file in the registry, an unreadable entry, a failed write to standard output |

Diagnostics go to standard error as `evar: <message>`; standard output carries
only data. A diagnostic can name a scope or variable but never contains a
stored value. A concurrent `unset` can make a path disappear mid-operation; an
entry that has vanished is "missing", while a real I/O error is always exit 3.

## 6. Storage and safety

- **Atomic writes.** `set` writes `value\n` to a hidden file created by
  `mktemp` in the target directory (`.evar-write.XXXXXX`, mode `0600`) and then
  renames it over the target with `mv -f`. A reader sees the old or the new
  complete value. The temp file is removed on failure and on `SIGHUP`,
  `SIGINT`, or `SIGTERM`; a process killed with `SIGKILL` leaves one hidden
  temp file, which every command ignores.
- **Modes.** Directories `evar` creates are `0700`; value files are `0600`
  (an overwritten file is replaced, so it becomes `0600`). Pre-existing
  directories keep their modes.
- **No symlinks, no surprises.** Every path component below the root is
  checked and never followed; a symlink or a wrong file type is exit 3. Only
  the root's last component is checked, not its ancestors (many systems
  symlink `/tmp`, `/var`, or `~/.config`).
- **No evaluation.** Stored values are read as bytes and written with
  `syswrite` (falling back to `print`); they are never passed to `eval` or
  `source`, never run as a command, and never placed on a command line
  (validation hands them to `iconv` and `grep` through a pipe).
- **Validate first.** Scope, variable, and value are fully validated before
  the first directory is created. If a `set` is rejected after creating
  directories because another writer created a case-variant concurrently, the
  directories it created are removed again.

## 7. Concurrency

There is no cross-process locking: when two writers race, the last rename wins.
Because writes are atomic renames, a concurrent reader sees a complete value
and never a partial file. `set` retries once if its scope directory is pruned
by a concurrent `unset`. The exact-case conflict check is not atomic against
truly simultaneous creators, and path checks are not race-free against a local
attacker who can already modify the registry (see `SECURITY.md`).

## 8. Deliberate differences from the original draft

The implementation tightens or clarifies the initial design draft:

- Names may not end in `.`, and reserved device names are matched on the stem
  before the first `.` and also apply to variables (cross-OS portability).
- Names are exact-case on every OS, and `set` rejects case-only conflicts.
- Temp files are `mktemp` files named `.evar-write.XXXXXX`, not
  `<variable>.tmp.$$`.
- Directories are created `0700` at every level, not only the leaf.
- All trailing `\r`/`\n` are stripped on read, not one.
- Corrupt stored files and multi-line `--stdin` input are rejected rather than
  truncated; zero-byte `--stdin` is rejected.
- A missing explicit `list` prefix is exit 1; `list` always prints full scope
  paths.
- A relative `EVAR_HOME`, a symlinked root, and unsafe entries are errors.

## 9. Not supported in 0.1

Shell export emission (`evar export`), running a command with a scope injected
(`evar run`), layered `_` to `<version>` fallback, shell completions, and a
plugin file. `evar` has no knowledge of `dsec` manifests.
