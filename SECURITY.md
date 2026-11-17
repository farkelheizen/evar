# Security

`evar` is for non-secret configuration on a local workstation. It is not a
secret manager. Do not store passwords, tokens, private keys, or other secrets
in its registry. Configuration can be sensitive even when it is not a
credential, so treat the registry accordingly.

## Storage and trust

- **Plaintext at rest.** Every value is stored as plain text, one file per
  variable. There is no encryption.
- **Permissions are not access control for you.** `evar` creates directories
  with mode `0700` and value files with mode `0600`, which keeps other local
  user accounts out. They do not protect values from the account owner, from
  `root`, from other processes running as you, or from anything that copies the
  files: Time Machine and other backups, and sync tools if `~/.config` (or
  `EVAR_HOME`) is synchronized. Existing directories keep their modes; `evar`
  does not tighten them.
- **Values are data.** `evar` reads and writes values as bytes and never
  evaluates, sources, or expands them. Software that consumes `evar get` output
  is responsible for how it uses the value. For example, passing it to `eval`
  recreates the risk `evar` avoids.
- **Validation.** Scope names, variable names, and values are validated before
  anything is written (single-line UTF-8, no NUL), and a stored file edited by
  hand is validated on read. A value that is invalid is rejected, never
  truncated or guessed.

## Where values can be exposed

- **`get` and `list`** print values to standard output by design. They then end
  up in terminals, scrollback, logs, and anything that captures output.
- **`set <scope> <VAR> <VALUE>`** puts the value on a command line, where it is
  visible to other processes of the same user in the process list (`ps`) and is
  usually saved in shell history. `--stdin` avoids both for `evar` itself,
  though the value still comes from wherever you piped it. (Again: do not store
  secrets.)
- **Names are not secret either.** Error messages and `list` output include
  org, module, version, and variable names, and the directory layout is visible
  to anything that can read the registry.
- **Diagnostics never include stored values**, but they do name the scope or
  variable involved.
- **Killed writes leave plaintext behind.** A process killed with `SIGKILL`
  between creating and renaming its temporary file can leave a hidden
  `.evar-write.*` file (mode `0600`) containing the value being written.
  `evar` ignores such files but does not delete them; `SIGHUP`, `SIGINT`, and
  `SIGTERM` clean up the temp file.
- **`.DS_Store` and other stray files** are ignored by `evar` and are not
  removed by `unset`; they also keep their directory from being pruned.

## Filesystem safety and its limits

- **Symlinks and wrong file types** at any level below the registry root are
  refused with exit 3 and are never followed or traversed. A symlinked registry
  root is also refused.
- **Root ancestors are trusted.** Only the root's final path component is
  checked, not the directories above it, because macOS itself symlinks `/tmp`,
  `/var`, and `/etc` and many users symlink `~/.config`. Point `EVAR_HOME` only
  at a location you control.
- **Not race-free against a local attacker.** The checks are separate system
  calls, and Zsh cannot do descriptor-anchored (`openat`-style) traversal. An
  attacker who can already modify files inside your `0700` registry could swap
  a directory for a symlink between a check and its use. `evar` assumes the
  registry is private to your account.
- **No locking.** Concurrent writers can race and the last one wins. Writes are
  atomic renames, so a reader never sees a partial value, but `evar` does not
  guarantee any particular winner. The exact-case conflict check can also be
  bypassed by truly simultaneous creators on a case-sensitive filesystem.
- **Case-insensitive filesystems.** Names are matched exactly, including case,
  and `set` refuses names that differ only by case, so a registry behaves the
  same on macOS and Linux.
- **Unexpected files fail loudly.** A file or directory with a valid-looking
  name but the wrong type or a symlink in the registry makes commands that
  enumerate it exit 3 instead of being skipped silently.

## Reporting

No private vulnerability reporting channel is configured yet. Do not put
sensitive vulnerability details in a public issue. Maintainers must enable and
document a real private reporting route before publication.
