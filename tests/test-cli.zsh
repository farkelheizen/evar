#!/bin/zsh

EVAR_SCRIPT="${0:A:h:h}/evar"
source "${0:A:h}/lib.zsh"

# ---- Help and version ------------------------------------------------------

begin_test 'help forms are identical and go to stdout'
run_evar --help
check_status 0
[[ $OUT == 'Usage: evar'* ]] && (( ++T_PASS )) || t_fail 'help does not start with the usage line'
check_err_empty
cp "$OUT_FILE" "$TEST_ROOT/help.expected"
for form in help -h; do
  run_evar $form
  check_status 0 "evar $form"
  /usr/bin/cmp -s "$OUT_FILE" "$TEST_ROOT/help.expected" && (( ++T_PASS )) || t_fail "evar $form differs from --help"
done

begin_test 'no arguments prints help and exits 0'
run_evar
check_status 0
/usr/bin/cmp -s "$OUT_FILE" "$TEST_ROOT/help.expected" && (( ++T_PASS )) || t_fail 'no-argument output differs from --help'
check_err_empty

begin_test 'help lists every command, the exit codes, and EVAR_HOME'
run_evar --help
for word in get set unset exists list --stdin --force --no-newline EVAR_HOME '_' ' 1 ' ' 2 ' ' 3 '; do
  [[ $OUT == *"$word"* ]] && (( ++T_PASS )) || t_fail "help does not mention ${(q)word}"
done

begin_test 'version'
for form in --version -V; do
  run_evar $form
  check_status 0 "evar $form"
  check_out_exact $'evar 0.1.0-dev\n' "evar $form output"
  check_err_empty
done

# ---- Unsupported input -----------------------------------------------------

begin_test 'extra arguments after help or version are rejected'
for args in '--version extra' '-V extra' 'help extra' '--help extra'; do
  run_evar ${=args}
  check_status 1 "evar $args"
  check_err_has 'evar: unexpected argument'
  check_out_empty "stdout of evar $args"
done

begin_test 'unknown command'
run_evar frobnicate
check_status 1
check_err_has "evar: unknown command 'frobnicate'"
check_out_empty

begin_test 'unknown top-level option'
run_evar --bogus
check_status 1
check_err_has "evar: unknown option '--bogus'"
check_out_empty

begin_test 'bare -- is not a command'
run_evar --
check_status 1
check_err_has 'evar: unknown option'

# ---- Error helpers (unit) --------------------------------------------------

begin_test 'fail helpers map to exit codes 1, 2 and 3'
for pair in 'usage_fail 1' 'value_fail 2' 'io_fail 3'; do
  fn=${pair% *} code=${pair#* }
  run_fn $fn 'synthetic message'
  check_status $code "$fn exit code"
  check_eq "$ERR" 'evar: synthetic message' "$fn stderr"
  check_out_empty "$fn stdout"
done

# ---- Option parsing (unit) -------------------------------------------------
# parse_args <command> <allowed options> [args...] sets OPT_* and ARGS.

typeset -g DUMP='parse_args "$@"; print -r -- "n=$OPT_NO_NEWLINE f=$OPT_FORCE s=$OPT_STDIN a=${(j:|:)ARGS}"'

begin_test 'options may appear anywhere before --'
run_snippet "$DUMP" get 'no-newline' a/b -n VAR
check_status 0
check_out 'n=1 f=0 s=0 a=a/b|VAR'
run_snippet "$DUMP" get 'no-newline' --no-newline a/b VAR
check_out 'n=1 f=0 s=0 a=a/b|VAR'
run_snippet "$DUMP" unset 'force' a/b VAR --force
check_out 'n=0 f=1 s=0 a=a/b|VAR'
run_snippet "$DUMP" unset 'force' -f a/b VAR
check_out 'n=0 f=1 s=0 a=a/b|VAR'
run_snippet "$DUMP" set 'stdin' a/b VAR --stdin
check_out 'n=0 f=0 s=1 a=a/b|VAR'

begin_test 'everything after -- is positional'
run_snippet "$DUMP" set 'stdin' -- a/b VAR -- -n --stdin
check_status 0
check_out 'n=0 f=0 s=0 a=a/b|VAR|--|-n|--stdin'
run_snippet "$DUMP" set 'stdin' a/b VAR -- -dashed
check_out 'n=0 f=0 s=0 a=a/b|VAR|-dashed'

begin_test 'a lone - and plain words are positional'
run_snippet "$DUMP" list '' - word
check_out 'n=0 f=0 s=0 a=-|word'

begin_test 'unknown or disallowed options fail with exit 1'
run_snippet "$DUMP" get 'no-newline' --bogus a/b VAR
check_status 1
check_err_has "evar: unknown option '--bogus' for 'get'"
run_snippet "$DUMP" set 'stdin' -n a/b VAR v
check_status 1
check_err_has "evar: unknown option '-n' for 'set'"
run_snippet "$DUMP" set 'stdin' a/b VAR -val
check_status 1
check_err_has "evar: unknown option '-val' for 'set'"
run_snippet "$DUMP" exists '' --force a/b
check_status 1
check_out_empty

begin_test 'help flag prints per-command help and exits 0 before other checks'
for cmd in get set unset exists list; do
  run_snippet "$DUMP" $cmd '' --bogus -h
  check_status 1 "$cmd: unknown option seen before -h"
  run_snippet "$DUMP" $cmd '' -h --bogus
  check_status 0 "$cmd -h"
  [[ $OUT == "Usage: evar $cmd"* ]] && (( ++T_PASS )) || t_fail "$cmd help does not start with its usage line"
  check_err_empty
done

# ---- Phase 3: registry root ------------------------------------------------

mkfile() { # path content: create a variable file (and parents) by hand
  /bin/mkdir -p -- "${1:h}"
  print -r -- "$2" > "$1"
}

typeset -g DUMP_ROOT='registry_root; print -r -- "$REGISTRY_ROOT"'

# Each row: description|env args (space separated)|expected root
typeset -a ROOT_CASES=(
  'EVAR_HOME is the root itself|EVAR_HOME=/tmp/r1|/tmp/r1'
  'trailing slashes are removed|EVAR_HOME=/tmp/r1//|/tmp/r1'
  'EVAR_HOME wins over XDG_CONFIG_HOME|EVAR_HOME=/tmp/r1 XDG_CONFIG_HOME=/tmp/xdg|/tmp/r1'
  'empty EVAR_HOME is unset|EVAR_HOME= XDG_CONFIG_HOME=/tmp/xdg|/tmp/xdg/evar/registry'
  'XDG_CONFIG_HOME default|XDG_CONFIG_HOME=/tmp/xdg|/tmp/xdg/evar/registry'
  'HOME default|HOME=/tmp/h|/tmp/h/.config/evar/registry'
  'empty XDG_CONFIG_HOME is unset|XDG_CONFIG_HOME= HOME=/tmp/h|/tmp/h/.config/evar/registry'
)
for row in "${ROOT_CASES[@]}"; do
  parts=("${(@s:|:)row}")
  begin_test "registry_root: $parts[1]"
  run_snippet_raw -u EVAR_HOME -u XDG_CONFIG_HOME HOME="$TEST_HOME" ${=parts[2]} -- "$DUMP_ROOT"
  check_status 0
  check_out "$parts[3]"
done

begin_test 'registry_root: paths with spaces and glob characters are kept verbatim'
run_snippet_raw -u XDG_CONFIG_HOME HOME="$TEST_HOME" "EVAR_HOME=$TEST_ROOT/we ird[x]*/reg" -- "$DUMP_ROOT"
check_status 0
check_out "$TEST_ROOT/we ird[x]*/reg"

begin_test 'registry_root: deriving the root creates nothing'
run_snippet_raw -u EVAR_HOME -u XDG_CONFIG_HOME HOME="$TEST_HOME" -- "$DUMP_ROOT"
check_status 0
check_no_path "$TEST_HOME/.config"

typeset -a BAD_ROOTS=(
  'relative EVAR_HOME|EVAR_HOME=rel/path'
  'dot-relative EVAR_HOME|EVAR_HOME=./reg'
  'tilde EVAR_HOME is not expanded|EVAR_HOME=~/reg'
  'filesystem root|EVAR_HOME=/'
  'only slashes|EVAR_HOME=///'
  'relative XDG_CONFIG_HOME|-u EVAR_HOME XDG_CONFIG_HOME=cfg'
  'no root can be derived|-u EVAR_HOME -u XDG_CONFIG_HOME HOME='
)
for row in "${BAD_ROOTS[@]}"; do
  parts=("${(@s:|:)row}")
  begin_test "registry_root rejects: $parts[1]"
  run_snippet_raw ${=parts[2]} -- "$DUMP_ROOT"
  check_status 1
  check_out_empty
  [[ $ERR == 'evar: '* ]] && (( ++T_PASS )) || t_fail "diagnostic lacks the evar: prefix: ${(q)ERR}"
done

# ---- Phase 3: private directories ------------------------------------------

begin_test 'ensure_private_dir creates every missing level with mode 700'
run_fn ensure_private_dir "$EVAR_HOME/acme/app/_"
check_status 0
for p in "$EVAR_HOME" "$EVAR_HOME/acme" "$EVAR_HOME/acme/app" "$EVAR_HOME/acme/app/_"; do
  check_mode "$p" 700
done

begin_test 'ensure_private_dir is idempotent and never chmods an existing directory'
/bin/mkdir -p -- "$EVAR_HOME/acme"
/bin/chmod 755 "$EVAR_HOME" "$EVAR_HOME/acme"
run_fn ensure_private_dir "$EVAR_HOME/acme"
check_status 0
check_mode "$EVAR_HOME" 755
check_mode "$EVAR_HOME/acme" 755
run_fn ensure_private_dir "$EVAR_HOME/acme/app"
check_status 0
check_mode "$EVAR_HOME/acme/app" 700
check_mode "$EVAR_HOME/acme" 755

begin_test 'ensure_private_dir refuses symlinks and non-directories'
/bin/mkdir -p -- "$EVAR_HOME" "$TEST_ROOT/outside"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/linked"
ln -s "$TEST_ROOT/nowhere" "$EVAR_HOME/dangling"
print -r -- x > "$EVAR_HOME/plainfile"
for name in linked dangling plainfile; do
  run_fn ensure_private_dir "$EVAR_HOME/$name"
  check_status 3 "ensure_private_dir over $name"
done

# ensure_scope_dirs <org> <module> <version> creates the registry root and each
# scope level one at a time, so it can never create anything through a symlink.
begin_test 'ensure_scope_dirs creates the root and every level with mode 700'
run_snippet 'registry_root; ensure_scope_dirs "$@"' acme app dev
check_status 0
for p in "$EVAR_HOME" "$EVAR_HOME/acme" "$EVAR_HOME/acme/app" "$EVAR_HOME/acme/app/dev"; do
  check_mode "$p" 700
done

begin_test 'ensure_scope_dirs reuses existing levels without changing them'
/bin/mkdir -p -- "$EVAR_HOME/acme/app/dev"
/bin/chmod 755 "$EVAR_HOME" "$EVAR_HOME/acme" "$EVAR_HOME/acme/app"
run_snippet 'registry_root; ensure_scope_dirs "$@"' acme app _
check_status 0
check_mode "$EVAR_HOME/acme/app" 755
check_mode "$EVAR_HOME/acme/app/_" 700
check_path "$EVAR_HOME/acme/app/dev"

begin_test 'ensure_scope_dirs refuses symlinks at each level and creates nothing through them'
/bin/mkdir -p -- "$TEST_ROOT/outside"
for level in 1 2 3; do
  /bin/rm -rf -- "$EVAR_HOME" "$TEST_ROOT/outside"
  /bin/mkdir -p -- "$TEST_ROOT/outside/app/_" "$EVAR_HOME"
  case $level in
    1) ln -s "$TEST_ROOT/outside" "$EVAR_HOME/acme" ;;
    2) /bin/mkdir -p -- "$EVAR_HOME/acme"; ln -s "$TEST_ROOT/outside/app" "$EVAR_HOME/acme/app" ;;
    3) /bin/mkdir -p -- "$EVAR_HOME/acme/app"; ln -s "$TEST_ROOT/outside/app/_" "$EVAR_HOME/acme/app/_" ;;
  esac
  before=$(/usr/bin/find "$TEST_ROOT/outside" | /usr/bin/sort)
  run_snippet 'registry_root; ensure_scope_dirs "$@"' acme app _
  check_status 3 "symlink at level $level"
  check_err_has 'symlink'
  check_eq "$(/usr/bin/find "$TEST_ROOT/outside" | /usr/bin/sort)" "$before" "outside tree after level $level"
done

# ---- Phase 3: exact-case lookup (D7) ---------------------------------------

typeset -g DUMP_FIND='find_entry "$1" "$2"; rc=$?; print -r -- "rc=$rc found=${FOUND_PATH:t} conflict=$CASE_CONFLICT"'

begin_test 'find_entry matches names exactly'
mkfile "$EVAR_HOME/Dir/Foo" x
run_snippet "$DUMP_FIND" "$EVAR_HOME/Dir" Foo
check_status 0
check_out 'rc=0 found=Foo conflict='
run_snippet "$DUMP_FIND" "$EVAR_HOME/Dir" Bar
check_out 'rc=1 found= conflict='

begin_test 'find_entry treats a case-only match as missing and names the conflict'
mkfile "$EVAR_HOME/Dir/Foo" x
for variant in foo FOO fOO; do
  run_snippet "$DUMP_FIND" "$EVAR_HOME/Dir" $variant
  check_status 0 "find_entry $variant"
  check_out 'rc=1 found= conflict=Foo' "find_entry $variant"
done

begin_test 'find_entry ignores the OS case-insensitive lookup'
mkfile "$EVAR_HOME/Dir/Foo" x
if fs_case_insensitive; then
  [[ -e $EVAR_HOME/Dir/foo ]] && (( ++T_PASS )) || t_fail 'precondition: the filesystem should resolve foo to Foo'
  run_snippet "$DUMP_FIND" "$EVAR_HOME/Dir" foo
  check_out 'rc=1 found= conflict=Foo' 'case-insensitive filesystem'
else
  skip_test 'needs a case-insensitive filesystem; the logic is covered by the previous test'
fi

begin_test 'find_entry distinguishes case-differing siblings on a case-sensitive filesystem'
if fs_case_insensitive; then
  skip_test 'needs a case-sensitive filesystem'
else
  mkfile "$EVAR_HOME/Dir/Foo" x
  mkfile "$EVAR_HOME/Dir/foo" y
  for variant in Foo foo; do
    run_snippet "$DUMP_FIND" "$EVAR_HOME/Dir" $variant
    check_out "rc=0 found=$variant conflict=" "find_entry $variant"
  done
fi

begin_test 'find_entry ignores hidden entries and treats the directory literally'
weird="$EVAR_HOME/we ird[x]*"
mkfile "$weird/Real" x
mkfile "$weird/.hidden" x
mkfile "$weird/.DS_Store" x
run_snippet "$DUMP_FIND" "$weird" Real
check_out 'rc=0 found=Real conflict='
run_snippet "$DUMP_FIND" "$weird" .hidden
check_out 'rc=1 found= conflict='
run_snippet "$DUMP_FIND" "$EVAR_HOME/we ird[x]*" Other
check_out 'rc=1 found= conflict='

begin_test 'find_entry reports an unreadable directory as an I/O error'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkfile "$EVAR_HOME/Dir/Foo" x
  /bin/chmod 000 "$EVAR_HOME/Dir"
  run_snippet "$DUMP_FIND" "$EVAR_HOME/Dir" Foo
  check_status 3
  /bin/chmod 700 "$EVAR_HOME/Dir"
fi

# ---- Phase 3: safe path layer ----------------------------------------------
# resolve_chain <dir|file> <segment>... walks REGISTRY_ROOT one exact-case
# segment at a time. 0 = every segment exists; 1 = stopped at the first missing
# one; unsafe objects exit 3.

typeset -g DUMP_CHAIN='registry_root; resolve_chain "$@"; rc=$?; print -r -- "rc=$rc count=$RESOLVED_COUNT rel=${RESOLVED_PATH#"$REGISTRY_ROOT"} conflict=$CASE_CONFLICT missing=$MISSING_SEGMENT"; exit $rc'

begin_test 'resolve_chain finds a complete path'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
run_snippet "$DUMP_CHAIN" file acme app _ NAME
check_status 0
check_out 'rc=0 count=4 rel=/acme/app/_/NAME conflict= missing='
run_snippet "$DUMP_CHAIN" dir acme app _
check_status 0
check_out 'rc=0 count=3 rel=/acme/app/_ conflict= missing='

begin_test 'resolve_chain stops at the first missing segment'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
run_snippet "$DUMP_CHAIN" file other app _ NAME
check_status 1
check_out 'rc=1 count=0 rel= conflict= missing=other'
run_snippet "$DUMP_CHAIN" file acme nomod _ NAME
check_out 'rc=1 count=1 rel=/acme conflict= missing=nomod'
run_snippet "$DUMP_CHAIN" file acme app dev NAME
check_out 'rc=1 count=2 rel=/acme/app conflict= missing=dev'
run_snippet "$DUMP_CHAIN" file acme app _ OTHER
check_out 'rc=1 count=3 rel=/acme/app/_ conflict= missing=OTHER'

begin_test 'resolve_chain: an absent registry is simply missing'
run_snippet "$DUMP_CHAIN" file acme app _ NAME
check_status 1
check_out 'rc=1 count=0 rel= conflict= missing='
check_no_path "$EVAR_HOME"

begin_test 'resolve_chain reports case-only differences at any level as missing, with the conflict'
mkfile "$EVAR_HOME/Acme/App/Dev/Name" v
run_snippet "$DUMP_CHAIN" file acme App Dev Name
check_out 'rc=1 count=0 rel= conflict=Acme missing=acme'
run_snippet "$DUMP_CHAIN" file Acme app Dev Name
check_out 'rc=1 count=1 rel=/Acme conflict=App missing=app'
run_snippet "$DUMP_CHAIN" file Acme App dev Name
check_out 'rc=1 count=2 rel=/Acme/App conflict=Dev missing=dev'
run_snippet "$DUMP_CHAIN" file Acme App Dev NAME
check_out 'rc=1 count=3 rel=/Acme/App/Dev conflict=Name missing=NAME'
run_snippet "$DUMP_CHAIN" file Acme App Dev Name
check_status 0

begin_test 'resolve_chain refuses a symlink at every level (exit 3)'
mkfile "$TEST_ROOT/outside/app/_/NAME" secret-synthetic
for level in 1 2 3 4; do
  /bin/rm -rf -- "$EVAR_HOME"
  mkfile "$EVAR_HOME/real/app/_/NAME" v
  case $level in
    1) /bin/rm -rf -- "$EVAR_HOME/real"; ln -s "$TEST_ROOT/outside" "$EVAR_HOME/real" ;;
    2) /bin/rm -rf -- "$EVAR_HOME/real/app"; ln -s "$TEST_ROOT/outside/app" "$EVAR_HOME/real/app" ;;
    3) /bin/rm -rf -- "$EVAR_HOME/real/app/_"; ln -s "$TEST_ROOT/outside/app/_" "$EVAR_HOME/real/app/_" ;;
    4) /bin/rm -f -- "$EVAR_HOME/real/app/_/NAME"; ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/real/app/_/NAME" ;;
  esac
  run_snippet "$DUMP_CHAIN" file real app _ NAME
  check_status 3 "symlink at level $level"
  check_err_has 'symlink'
  check_out_empty "stdout for symlink at level $level"
done

begin_test 'resolve_chain refuses a dangling symlink and a symlinked registry root'
mkfile "$EVAR_HOME/acme/app/_/x" v
ln -s "$TEST_ROOT/nowhere" "$EVAR_HOME/acme/app/_/NAME"
run_snippet "$DUMP_CHAIN" file acme app _ NAME
check_status 3 'dangling symlink'
/bin/rm -rf -- "$EVAR_HOME"
/bin/mkdir -p -- "$TEST_ROOT/realroot/acme"
ln -s "$TEST_ROOT/realroot" "$EVAR_HOME"
run_snippet "$DUMP_CHAIN" dir acme
check_status 3 'symlinked registry root'
check_err_has 'symlink'

begin_test 'resolve_chain refuses a wrong file type (exit 3)'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
/bin/mkdir -p -- "$EVAR_HOME/acme/app/_/DIRVAR"
run_snippet "$DUMP_CHAIN" file acme app _ DIRVAR
check_status 3 'directory where a variable file is expected'
/usr/bin/mkfifo "$EVAR_HOME/acme/app/_/FIFOVAR"
run_snippet "$DUMP_CHAIN" file acme app _ FIFOVAR
check_status 3 'fifo where a variable file is expected'
run_snippet "$DUMP_CHAIN" dir acme app _ NAME
check_status 3 'regular file where a directory is expected (leaf)'
run_snippet "$DUMP_CHAIN" file acme app _ NAME x
check_status 3 'regular file in the middle of the chain'
print -r -- x > "$EVAR_HOME/orgfile"
run_snippet "$DUMP_CHAIN" file orgfile app _ NAME
check_status 3 'regular file where an org directory is expected'
/bin/rm -rf -- "$EVAR_HOME"
print -r -- x > "$EVAR_HOME"
run_snippet "$DUMP_CHAIN" file acme app _ NAME
check_status 3 'registry root is a regular file'

begin_test 'resolve_chain reports an unreadable directory as an I/O error'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkfile "$EVAR_HOME/acme/app/_/NAME" v
  /bin/chmod 000 "$EVAR_HOME/acme/app"
  run_snippet "$DUMP_CHAIN" file acme app _ NAME
  check_status 3
  /bin/chmod 700 "$EVAR_HOME/acme/app"
fi

begin_test 'diagnostics use registry-relative names, never contents'
mkfile "$EVAR_HOME/acme/app/_/NAME" CANARYVALUE
/bin/rm -f -- "$EVAR_HOME/acme/app/_/NAME"
ln -s "$TEST_ROOT/nowhere" "$EVAR_HOME/acme/app/_/NAME"
run_snippet "$DUMP_CHAIN" file acme app _ NAME
check_status 3
check_err_has 'acme/app/_/NAME'
check_err_lacks 'CANARYVALUE'

# ---- Phase 4: read, write, delete primitives -------------------------------
# Each primitive takes <org> <module> <version> [<VAR>] and re-verifies the
# whole registry path itself (exact case, no symlinks), so it is safe on its
# own. write_var_file <org> <module> <version> <VAR> <value> additionally
# enforces the exact-case rule for names it would create.

typeset -g WRITE='registry_root; write_var_file "$@"'
typeset -g PRUNE='registry_root; prune_empty_dirs "$@"'
# read_var_file <org> <module> <version> <VAR>: 0 = value in REPLY, 1 = missing.
typeset -g READ='registry_root; read_var_file "$@"; rc=$?; print -rn -- "${REPLY-}"; exit $rc'

begin_test 'write_var_file creates private directories and a 0600 file holding value + newline'
run_snippet "$WRITE" acme app dev NAME 'hello world'
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/dev/NAME" $'hello world\n'
for p in "$EVAR_HOME" "$EVAR_HOME/acme" "$EVAR_HOME/acme/app" "$EVAR_HOME/acme/app/dev"; do
  check_mode "$p" 700
done
check_mode "$EVAR_HOME/acme/app/dev/NAME" 600
check_no_temp "$EVAR_HOME"
check_out_empty

begin_test 'write_var_file overwrites atomically and resets the file mode'
mkfile "$EVAR_HOME/acme/app/_/NAME" old
/bin/chmod 644 "$EVAR_HOME/acme/app/_/NAME"
run_snippet "$WRITE" acme app _ NAME new
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'new\n'
check_mode "$EVAR_HOME/acme/app/_/NAME" 600
check_no_temp "$EVAR_HOME"

begin_test 'write_var_file stores an empty value as a single newline'
run_snippet "$WRITE" acme app _ EMPTY ''
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/EMPTY" $'\n'

typeset -a ROUNDTRIP_VALUES=(
  plain 'with space' '  padded  ' 'a=b=c' '-n' '-e' '--' '-leading' "it's" 'say "hi"'
  '$HOME' '${HOME}' '$(touch CANARY)' '`touch CANARY`' 'a;b|c&d' '*?[a-z]' '~' '#'
  '\n literal' 'tab\tliteral' '%s %d' '\' 'é' '日本語' '😀' 'ƒ ¡' $'tab\there'
  $'\xc3\x83 \xc2\xa1 \xc2\x9b'
)
begin_test 'values round-trip byte for byte and are never evaluated'
i=0
for v in "${ROUNDTRIP_VALUES[@]}"; do
  var="V$(( ++i ))"
  run_snippet "$WRITE" acme app _ "$var" "$v"
  check_status 0 "write ${(qq)v}"
  check_file_bytes "$EVAR_HOME/acme/app/_/$var" "$v"$'\n' "stored bytes of ${(qq)v}"
  run_snippet "$READ" acme app _ "$var"
  check_status 0 "read ${(qq)v}"
  check_out_exact "$v" "round trip of ${(qq)v}"
done
check_no_path "$PWD/CANARY"
check_no_path "$TEST_ROOT/CANARY"

begin_test 'write_var_file validates before touching the filesystem'
run_snippet "$WRITE" acme app _ NAME $'line one\nline two'
check_status 2
check_no_path "$EVAR_HOME"

begin_test 'write_var_file refuses a symlink or directory at the target (exit 3)'
mkfile "$TEST_ROOT/outside/secret" untouched-synthetic
/bin/mkdir -p -- "$EVAR_HOME/acme/app/_/DIRVAR"
ln -s "$TEST_ROOT/outside/secret" "$EVAR_HOME/acme/app/_/LINKVAR"
run_snippet "$WRITE" acme app _ LINKVAR replaced
check_status 3 'symlink target'
check_file_bytes "$TEST_ROOT/outside/secret" $'untouched-synthetic\n' 'symlink destination'
run_snippet "$WRITE" acme app _ DIRVAR replaced
check_status 3 'directory target'
check_no_temp "$EVAR_HOME"

begin_test 'write_var_file fails with exit 3 and leaves no temp file when the directory is read-only'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkfile "$EVAR_HOME/acme/app/_/NAME" keep
  /bin/chmod 500 "$EVAR_HOME/acme/app/_"
  run_snippet "$WRITE" acme app _ NAME changed
  check_status 3
  check_err_has 'evar: '
  /bin/chmod 700 "$EVAR_HOME/acme/app/_"
  check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'keep\n' 'existing value after failed write'
  check_no_temp "$EVAR_HOME"
fi

begin_test 'write_var_file retries once if the scope directory vanishes after creation'
RACE='functions -c ensure_scope_dirs real_ensure_scope_dirs; typeset -gi calls=0
ensure_scope_dirs() { real_ensure_scope_dirs "$@"; if (( calls++ < LIMIT )); then /bin/rmdir -- "$REGISTRY_ROOT/$1/$2/$3"; fi }
registry_root; write_var_file acme app _ NAME value; print -r -- "calls=$calls"'
run_snippet "LIMIT=1; $RACE"
check_status 0 'one vanish'
check_out 'calls=2'
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'value\n'
/bin/rm -rf -- "$EVAR_HOME"
run_snippet "LIMIT=2; $RACE"
check_status 3 'two vanishes'
check_no_temp "$EVAR_HOME"

begin_test 'write_var_file enforces exact case: a case-only difference is a usage error (exit 1)'
mkfile "$EVAR_HOME/Acme/App/Dev/Name" v
before=$(/usr/bin/find "$EVAR_HOME" | /usr/bin/sort)
for args in 'acme App Dev Name' 'Acme app Dev Name' 'Acme App dev Name' 'Acme App Dev NAME'; do
  run_snippet "$WRITE" ${=args} x
  check_status 1 "write $args"
  check_err_has 'differ'
  check_out_empty "stdout for $args"
  check_eq "$(/usr/bin/find "$EVAR_HOME" | /usr/bin/sort)" "$before" "registry after rejected write $args"
done
check_err_has 'Name'
run_snippet "$WRITE" Acme App Dev Name updated
check_status 0 'exact-case write still works'
check_file_bytes "$EVAR_HOME/Acme/App/Dev/Name" $'updated\n'

begin_test 'write_var_file refuses a symlink in the middle of the path (exit 3) and writes nothing through it'
/bin/mkdir -p -- "$TEST_ROOT/outside/app/_" "$EVAR_HOME"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/acme"
run_snippet "$WRITE" acme app _ NAME x
check_status 3
check_no_path "$TEST_ROOT/outside/app/_/NAME"
check_no_temp "$TEST_ROOT/outside"

begin_test 'write_var_file re-checks exact case after creating directories (concurrent creator)'
# Simulates another writer creating "acme" just before this writer creates
# "Acme". On a case-insensitive disk mkdir would silently reuse "acme".
CREATE_VARIANT='functions -c ensure_scope_dirs real_ensure_scope_dirs
ensure_scope_dirs() { /bin/mkdir -p -- "$REGISTRY_ROOT/acme"; real_ensure_scope_dirs "$@"; }
registry_root; write_var_file Acme App Dev NAME value'
if fs_case_insensitive; then
  run_snippet "$CREATE_VARIANT"
  check_status 1
  check_err_has 'differ only by case'
  check_no_temp "$EVAR_HOME"
  check_eq "$(/usr/bin/find "$EVAR_HOME" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" 0 'files written'
else
  skip_test 'needs a case-insensitive filesystem (a case-sensitive one cannot detect this race)'
fi

begin_test 'discard_temp_file keeps the entry for the exit trap when removal fails'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  /bin/mkdir -p -- "$TEST_ROOT/locked"
  print -r -- x > "$TEST_ROOT/locked/.evar-write.AAAAAA"
  /bin/chmod 500 "$TEST_ROOT/locked"
  run_snippet 'EVAR_TEMP_FILES=("$1"); discard_temp_file "$1"; rc=$?; print -r -- "rc=$rc kept=${#EVAR_TEMP_FILES}"' "$TEST_ROOT/locked/.evar-write.AAAAAA"
  check_out 'rc=1 kept=1'
  /bin/chmod 700 "$TEST_ROOT/locked"
  run_snippet 'EVAR_TEMP_FILES=("$1"); discard_temp_file "$1"; rc=$?; print -r -- "rc=$rc kept=${#EVAR_TEMP_FILES}"' "$TEST_ROOT/locked/.evar-write.AAAAAA"
  check_out 'rc=0 kept=0'
  check_no_path "$TEST_ROOT/locked/.evar-write.AAAAAA"
fi

# read_var_file <org> <module> <version> <VAR> is defined with the other
# snippets above.

begin_test 'read_var_file returns the value with every trailing CR/LF stripped'
mkdir -p -- "$EVAR_HOME/acme/app/_"
printf 'v1\r\n\r\n' > "$EVAR_HOME/acme/app/_/CRLF"
printf 'v2\n\n\n' > "$EVAR_HOME/acme/app/_/LFS"
printf 'v3' > "$EVAR_HOME/acme/app/_/NONL"
printf '\n' > "$EVAR_HOME/acme/app/_/EMPTY"
for pair in 'CRLF v1' 'LFS v2' 'NONL v3' 'EMPTY '; do
  run_snippet "$READ" acme app _ "${pair% *}"
  check_status 0 "read ${pair% *}"
  check_out_exact "${pair#* }"
done

begin_test 'read_var_file reports a missing variable or scope as 1, with the case conflict'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
for args in 'acme app _ OTHER' 'acme app dev NAME' 'acme nomod _ NAME' 'nobody app _ NAME'; do
  run_snippet "$READ" ${=args}
  check_status 1 "read $args"
  check_out_empty "stdout for $args"
done
run_snippet "$READ" acme app _ name
check_status 1 'case-only variable name'
run_snippet "$READ" ACME app _ NAME
check_status 1 'case-only org name'
rm -rf -- "$EVAR_HOME"
run_snippet "$READ" acme app _ NAME
check_status 1 'absent registry'

begin_test 'read_var_file strips a very long trailing CR/LF run in linear time'
mkdir -p -- "$EVAR_HOME/acme/app/_"
{ print -rn -- 'v1'; /usr/bin/head -c 60000 /dev/zero | /usr/bin/tr '\0' '\r'; print -r -- ''; } > "$EVAR_HOME/acme/app/_/LONGRUN"
SECONDS=0
run_snippet "$READ" acme app _ LONGRUN
check_status 0
check_out_exact 'v1'
(( SECONDS < 10 )) && (( ++T_PASS )) || t_fail "stripping 60000 trailing CRs took ${SECONDS}s"

begin_test 'read_var_file rejects corrupt content (exit 2) without echoing it'
mkdir -p -- "$EVAR_HOME/acme/app/_"
printf 'CANARYVALUE\nsecond\n' > "$EVAR_HOME/acme/app/_/INTERIOR"
printf 'CANARYVALUE\xff\n' > "$EVAR_HOME/acme/app/_/BADUTF8"
printf 'CANARY\0VALUE\n' > "$EVAR_HOME/acme/app/_/WITHNUL"
printf 'CANARY\xf4\x90\x80\x80\n' > "$EVAR_HOME/acme/app/_/ABOVEMAX"
for f in INTERIOR BADUTF8 WITHNUL ABOVEMAX; do
  run_snippet "$READ" acme app _ $f
  check_status 2 "read $f"
  check_err_has "acme/app/_/$f"
  check_err_lacks CANARY
  check_out_empty "stdout for $f"
done

begin_test 'read_var_file refuses unsafe or unreadable entries (exit 3)'
mkdir -p -- "$EVAR_HOME/acme/app/_"
print -r -- v > "$TEST_ROOT/target"
ln -s "$TEST_ROOT/target" "$EVAR_HOME/acme/app/_/LINKVAR"
ln -s "$TEST_ROOT/nowhere" "$EVAR_HOME/acme/app/_/DANGLING"
mkdir -p -- "$EVAR_HOME/acme/app/_/DIRVAR"
/usr/bin/mkfifo "$EVAR_HOME/acme/app/_/FIFOVAR"
for f in LINKVAR DANGLING DIRVAR FIFOVAR; do
  run_snippet "$READ" acme app _ $f
  check_status 3 "read $f"
  check_out_empty "stdout for $f"
done
if is_root; then
  skip_test 'running as root; unreadable-file case needs enforced permissions'
else
  print -r -- v > "$EVAR_HOME/acme/app/_/NOPERM"
  /bin/chmod 000 "$EVAR_HOME/acme/app/_/NOPERM"
  run_snippet "$READ" acme app _ NOPERM
  check_status 3 'read chmod 000 file'
  /bin/chmod 600 "$EVAR_HOME/acme/app/_/NOPERM"
fi

# delete_var_file <org> <module> <version> <VAR>: 0 = deleted, 1 = missing.
typeset -g DELETE='registry_root; delete_var_file "$@"'

begin_test 'delete_var_file removes only the file and reports a missing one as 1'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
mkfile "$EVAR_HOME/acme/app/_/KEEP" v
run_snippet "$DELETE" acme app _ NAME
check_status 0
check_no_path "$EVAR_HOME/acme/app/_/NAME"
check_path "$EVAR_HOME/acme/app/_/KEEP"
run_snippet "$DELETE" acme app _ NAME
check_status 1 'already deleted'
run_snippet "$DELETE" acme app _ keep
check_status 1 'case-only variable name'
check_path "$EVAR_HOME/acme/app/_/KEEP"

begin_test 'delete_var_file refuses unsafe entries and never deletes through a symlink'
mkfile "$TEST_ROOT/outside/app/_/NAME" synthetic
/bin/mkdir -p -- "$EVAR_HOME"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/acme"
run_snippet "$DELETE" acme app _ NAME
check_status 3 'symlinked org'
check_path "$TEST_ROOT/outside/app/_/NAME"
/bin/rm -rf -- "$EVAR_HOME"
mkdir -p -- "$EVAR_HOME/acme/app/_/DIR"
ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/acme/app/_/LINK"
for f in DIR LINK; do
  run_snippet "$DELETE" acme app _ $f
  check_status 3 "delete $f"
  check_path "$EVAR_HOME/acme/app/_/$f"
done
check_path "$TEST_ROOT/outside/app/_/NAME"

# prune_empty_dirs <org> <module> <version>
begin_test 'prune_empty_dirs removes empty version, module and org directories but never the root'
mkdir -p -- "$EVAR_HOME/acme/app/_"
run_snippet "$PRUNE" acme app _
check_status 0
check_no_path "$EVAR_HOME/acme"
check_path "$EVAR_HOME"

begin_test 'prune_empty_dirs stops at the first non-empty directory'
mkdir -p -- "$EVAR_HOME/acme/app/_" "$EVAR_HOME/acme/app/dev" "$EVAR_HOME/acme/other/_"
run_snippet "$PRUNE" acme app _
check_status 0
check_no_path "$EVAR_HOME/acme/app/_"
check_path "$EVAR_HOME/acme/app/dev"
check_path "$EVAR_HOME/acme/app"
run_snippet "$PRUNE" acme app dev
check_status 0
check_no_path "$EVAR_HOME/acme/app"
check_path "$EVAR_HOME/acme/other/_"
check_path "$EVAR_HOME/acme"

begin_test 'prune_empty_dirs leaves a directory holding any file, including hidden ones'
mkfile "$EVAR_HOME/acme/app/_/.DS_Store" x
run_snippet "$PRUNE" acme app _
check_status 0
check_path "$EVAR_HOME/acme/app/_/.DS_Store"
mkfile "$EVAR_HOME/acme/app/dev/NAME" v
run_snippet "$PRUNE" acme app dev
check_path "$EVAR_HOME/acme/app/dev/NAME"

begin_test 'prune_empty_dirs ignores a scope that is already gone'
run_snippet "$PRUNE" acme app _
check_status 0
mkdir -p -- "$EVAR_HOME"
run_snippet "$PRUNE" acme app _
check_status 0
check_path "$EVAR_HOME"

begin_test 'prune_empty_dirs reports a directory it cannot remove as an I/O error (exit 3)'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkdir -p -- "$EVAR_HOME/acme/app/_"
  /bin/chmod 500 "$EVAR_HOME/acme/app"
  run_snippet "$PRUNE" acme app _
  check_status 3
  check_err_has 'acme/app/_'
  /bin/chmod 700 "$EVAR_HOME/acme/app"
  check_path "$EVAR_HOME/acme/app/_"
fi

begin_test 'prune_empty_dirs does not prune through a symlinked directory'
mkdir -p -- "$TEST_ROOT/outside/app/_" "$EVAR_HOME"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/acme"
run_snippet "$PRUNE" acme app _
check_status 3
check_path "$TEST_ROOT/outside/app/_"

# ---- Phase 5: set ----------------------------------------------------------

begin_test 'set stores a value in the default slot, silently'
run_evar set acme/app NAME 'hello world'
check_status 0
check_out_empty
check_err_empty
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'hello world\n'
for p in "$EVAR_HOME" "$EVAR_HOME/acme" "$EVAR_HOME/acme/app" "$EVAR_HOME/acme/app/_"; do
  check_mode "$p" 700
done
check_mode "$EVAR_HOME/acme/app/_/NAME" 600
check_no_temp "$EVAR_HOME"

begin_test 'set: omitted and explicit _ are the same slot; other versions are separate'
run_evar set acme/app NAME one
run_evar set acme/app/_ NAME two
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'two\n' 'explicit _ overwrites the default slot'
run_evar set acme/app/dev NAME three
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/dev/NAME" $'three\n'
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'two\n' 'default slot is untouched by dev'
run_evar set acme/app/v1-dev NAME four
check_file_bytes "$EVAR_HOME/acme/app/v1-dev/NAME" $'four\n'

begin_test 'set overwrites and accepts an empty value (D8)'
run_evar set acme/app NAME first
run_evar set acme/app NAME ''
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'\n'

begin_test 'set takes -- before a value that begins with a dash (D12)'
run_evar set -- acme/app NAME -dashed
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'-dashed\n'
run_evar set acme/app NAME -- --stdin
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'--stdin\n' 'literal --stdin after --'
run_evar set acme/app NAME -
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'-\n' 'a lone dash is a plain value'

begin_test 'set rejects a dash-leading value without -- (D12)'
run_evar set acme/app NAME -dashed
check_status 1
check_err_has "unknown option '-dashed' for 'set'"
check_no_path "$EVAR_HOME"

begin_test 'set argument-count and option errors are usage errors (exit 1)'
typeset -a BAD_SET_ARGS=(
  ''
  'acme/app'
  'acme/app NAME'
  'acme/app NAME v extra'
  '-- acme/app NAME'
  '--stdin'
  '--stdin acme/app'
  '--stdin acme/app NAME value'
  'acme/app NAME value --stdin'
  '--force acme/app NAME v'
  '--no-newline acme/app NAME v'
)
for args in "${BAD_SET_ARGS[@]}"; do
  run_evar set ${=args}
  check_status 1 "set $args"
  check_out_empty "stdout of set $args"
  check_no_path "$EVAR_HOME"
done

begin_test 'set --help prints help and exits 0'
run_evar set --help
check_status 0
[[ $OUT == 'Usage: evar set'* ]] && (( ++T_PASS )) || t_fail 'set --help does not start with its usage line'

# --stdin accepts exactly one line ended by LF, CRLF or end of input (D4).
typeset -a STDIN_OK=(
  'val\n|val'
  'val|val'
  'val\r\n|val'
  '\n|'
  '\r\n|'
  '  spaced value  \n|  spaced value  '
  'a=b\n|a=b'
  '$(touch CANARY)\n|$(touch CANARY)'
  '\xc3\xa9\xf0\x9f\x98\x80\n|é😀'
)
begin_test 'set --stdin stores exactly one line'
i=0
for row in "${STDIN_OK[@]}"; do
  parts=("${(@s:|:)row}")
  var="S$(( ++i ))"
  stdin_printf "$parts[1]"
  run_evar set acme/app $var --stdin
  check_status 0 "stdin ${(qq)parts[1]}"
  check_file_bytes "$EVAR_HOME/acme/app/_/$var" "${parts[2]-}"$'\n' "stored value for stdin ${(qq)parts[1]}"
done
check_no_path "$PWD/CANARY"

begin_test 'set --stdin accepts options before the positionals'
stdin_printf 'viaopt\n'
run_evar set --stdin acme/app NAME
check_status 0
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'viaopt\n'

begin_test 'set --stdin rejects zero bytes, extra lines, bare CR, NUL and bad UTF-8 (exit 2) without writing'
typeset -a STDIN_BAD=(
  ''
  'a\nb\n'
  'a\n\n'
  '\n\n'
  'a\nb'
  'a\rb\n'
  'a\r'
  'a\r\r\n'
  'a\0b\n'
  '\xff\n'
  'ok\xc3\n'
  '\xf4\x90\x80\x80\n'
)
for fmt in "${STDIN_BAD[@]}"; do
  rm -rf -- "$EVAR_HOME"
  stdin_printf "$fmt"
  run_evar set acme/app NAME --stdin
  check_status 2 "stdin ${(qq)fmt}"
  check_out_empty
  check_no_path "$EVAR_HOME"
done

begin_test 'set --stdin from a closed or empty source is rejected, never stored as empty'
run_evar set acme/app NAME --stdin
check_status 2
check_err_has 'no input'
check_no_path "$EVAR_HOME"

begin_test 'set validates scope, variable and value before touching the filesystem'
typeset -a BAD_SETS=(
  '1|a NAME v'
  '1|a/b/c/d NAME v'
  '1|a//b NAME v'
  '1|con/app NAME v'
  '1|acme./app NAME v'
  '1|acme/app/_x NAME v'
  '1|acme/app 1BAD v'
  '1|acme/app A-B v'
  '1|acme/app CON v'
  '1|acme/app NUL v'
)
for row in "${BAD_SETS[@]}"; do
  code=${row%%|*} args=${row#*|}
  run_evar set ${=args}
  check_status $code "set $args"
  check_no_path "$EVAR_HOME"
done
run_evar set acme/app '' v
check_status 1 'empty variable name'
check_no_path "$EVAR_HOME"
run_evar set acme/app NAME $'line one\nline two'
check_status 2 'multiline argument'
check_err_has 'single line'
check_no_path "$EVAR_HOME"
run_evar set acme/app NAME $'with\rcr'
check_status 2 'CR in argument'
run_evar set acme/app NAME $'\xff'
check_status 2 'invalid UTF-8 argument'
check_no_path "$EVAR_HOME"
run_evar set a/con NAME $'line\nbreak'
check_status 1 'an invalid scope outranks an invalid value'

begin_test 'set diagnostics never echo the value'
run_evar set acme/app NAME $'CANARYVALUE\nsecond'
check_status 2
check_err_lacks CANARYVALUE
run_evar set acme/app NAME $'CANARYVALUE\xff'
check_status 2
check_err_lacks CANARYVALUE

begin_test 'set stores special values literally and never evaluates them'
typeset -a LITERALS=('$(touch CANARY)' '`touch CANARY`' '${HOME}' '$HOME' '*' 'a;b' '"q"' "it's" '\n' '=' 'é')
i=0
for v in "${LITERALS[@]}"; do
  var="L$(( ++i ))"
  run_evar set acme/app $var "$v"
  check_status 0 "set ${(qq)v}"
  check_file_bytes "$EVAR_HOME/acme/app/_/$var" "$v"$'\n'
done
check_no_path "$PWD/CANARY"
check_no_path "$TEST_HOME/CANARY"

begin_test 'set rejects names that differ only by case from existing ones (D7)'
mkfile "$EVAR_HOME/Acme/App/Dev/Name" old
before=$(/usr/bin/find "$EVAR_HOME" | /usr/bin/sort)
for args in 'acme/App/Dev Name' 'Acme/app/Dev Name' 'Acme/App/dev Name' 'Acme/App/Dev NAME'; do
  run_evar set ${=args} new
  check_status 1 "set $args"
  check_err_has 'only by case'
  check_eq "$(/usr/bin/find "$EVAR_HOME" | /usr/bin/sort)" "$before" "registry after rejected set $args"
done
check_file_bytes "$EVAR_HOME/Acme/App/Dev/Name" $'old\n'
run_evar set Acme/App/Dev Name new
check_status 0
check_file_bytes "$EVAR_HOME/Acme/App/Dev/Name" $'new\n'

begin_test 'set refuses symlinks in the registry (exit 3) and writes nothing through them'
mkfile "$TEST_ROOT/outside/app/_/NAME" untouched
/bin/mkdir -p -- "$EVAR_HOME"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/acme"
run_evar set acme/app NAME changed
check_status 3 'symlinked org'
check_file_bytes "$TEST_ROOT/outside/app/_/NAME" $'untouched\n'
/bin/rm -f -- "$EVAR_HOME/acme"
mkfile "$EVAR_HOME/acme/app/_/KEEP" k
ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/acme/app/_/NAME"
run_evar set acme/app NAME changed
check_status 3 'symlinked variable'
check_file_bytes "$TEST_ROOT/outside/app/_/NAME" $'untouched\n'

begin_test 'set honors the default root derivation without touching the real home'
run_evar_raw -u EVAR_HOME -u XDG_CONFIG_HOME HOME="$TEST_HOME" -- set acme/app NAME viahome
check_status 0
check_file_bytes "$TEST_HOME/.config/evar/registry/acme/app/_/NAME" $'viahome\n'
run_evar_raw -u EVAR_HOME XDG_CONFIG_HOME="$TEST_ROOT/xdg" HOME="$TEST_HOME" -- set acme/app NAME viaxdg
check_status 0
check_file_bytes "$TEST_ROOT/xdg/evar/registry/acme/app/_/NAME" $'viaxdg\n'

begin_test 'set rejects a relative EVAR_HOME before touching anything'
run_evar_raw -u XDG_CONFIG_HOME HOME="$TEST_HOME" EVAR_HOME=relative-reg -- set acme/app NAME v
check_status 1
check_err_has 'absolute'
check_no_path "$PWD/relative-reg"

begin_test 'set reports an unwritable scope directory as an I/O error (exit 3)'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkfile "$EVAR_HOME/acme/app/_/NAME" keep
  /bin/chmod 500 "$EVAR_HOME/acme/app/_"
  run_evar set acme/app NAME changed
  check_status 3
  /bin/chmod 700 "$EVAR_HOME/acme/app/_"
  check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'keep\n'
  check_no_temp "$EVAR_HOME"
fi

# ---- Phase 5: get ----------------------------------------------------------

begin_test 'get prints the value and a newline; -n omits the newline'
run_evar set acme/app NAME 'hello world'
run_evar get acme/app NAME
check_status 0
check_out_exact $'hello world\n'
check_err_empty
for opt in -n --no-newline; do
  run_evar get $opt acme/app NAME
  check_status 0 "get $opt"
  check_out_exact 'hello world' "get $opt output"
  run_evar get acme/app NAME $opt
  check_out_exact 'hello world' "get ... $opt (option last)"
done
run_evar get -n -- acme/app NAME
check_out_exact 'hello world' 'get -n -- scope VAR'
run_evar get -- acme/app NAME
check_out_exact $'hello world\n' 'get -- scope VAR'

begin_test 'get: omitted and explicit _ are the same slot; versions are separate'
run_evar set acme/app NAME base
run_evar set acme/app/dev NAME devval
run_evar get acme/app/_ NAME
check_out base
run_evar get acme/app NAME
check_out base
run_evar get acme/app/dev NAME
check_out devval

begin_test 'get round-trips unusual values byte for byte'
typeset -a GET_VALUES=(
  '' plain 'with space' '  padded  ' 'a=b=c' '-n' '--' '-e' '$(touch CANARY)'
  '`touch CANARY`' '$HOME' '*' ';|&' '\n' '%s' 'é' '日本語' '😀' "it's" '"q"'
)
i=0
for v in "${GET_VALUES[@]}"; do
  var="G$(( ++i ))"
  run_evar set -- acme/app $var "$v"
  run_evar get acme/app $var
  check_status 0 "get ${(qq)v}"
  check_out_exact "$v"$'\n' "round trip of ${(qq)v}"
  run_evar get -n acme/app $var
  check_out_exact "$v" "round trip with -n of ${(qq)v}"
done
check_no_path "$PWD/CANARY"

begin_test 'get reports a missing variable, scope or registry as exit 1 on stderr only'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
for args in 'acme/app OTHER' 'acme/app/dev NAME' 'acme/nomod NAME' 'nobody/app NAME'; do
  run_evar get ${=args}
  check_status 1 "get $args"
  check_out_empty "stdout of get $args"
  check_err_has 'evar: not found:'
done
check_err_has 'nobody/app/_/NAME'
rm -rf -- "$EVAR_HOME"
run_evar get acme/app NAME
check_status 1 'absent registry'
check_no_path "$EVAR_HOME"

begin_test 'get is exact-case and explains a case-only mismatch'
mkfile "$EVAR_HOME/Acme/App/Dev/Name" v
for args in 'acme/App/Dev Name' 'Acme/app/Dev Name' 'Acme/App/dev Name' 'Acme/App/Dev NAME'; do
  run_evar get ${=args}
  check_status 1 "get $args"
  check_out_empty
  check_err_has 'match case exactly'
done
run_evar get Acme/App/Dev Name
check_status 0

begin_test 'get argument and scope errors are exit 1 and create nothing'
typeset -a BAD_GET_ARGS=('' 'acme/app' 'acme/app NAME extra' '--stdin acme/app NAME' '--force acme/app NAME'
  'a NAME' 'a/b/c/d NAME' 'a//b NAME' 'con/app NAME' 'acme/app 1BAD' 'acme/app CON' 'acme./app NAME')
for args in "${BAD_GET_ARGS[@]}"; do
  run_evar get ${=args}
  check_status 1 "get $args"
  check_out_empty "stdout of get $args"
  check_no_path "$EVAR_HOME"
done
run_evar get acme/app ''
check_status 1 'empty variable name'

begin_test 'get --help prints help and exits 0'
run_evar get -n --help
check_status 0
[[ $OUT == 'Usage: evar get'* ]] && (( ++T_PASS )) || t_fail 'get --help does not start with its usage line'

begin_test 'get strips every trailing CR/LF from hand-edited files'
mkdir -p -- "$EVAR_HOME/acme/app/_"
printf 'v1\r\n\r\n' > "$EVAR_HOME/acme/app/_/CRLF"
printf 'v2\n\n\n' > "$EVAR_HOME/acme/app/_/LFS"
printf 'v3' > "$EVAR_HOME/acme/app/_/NONL"
printf '  v4  \r\n' > "$EVAR_HOME/acme/app/_/SPACES"
for pair in 'CRLF v1' 'LFS v2' 'NONL v3' 'SPACES   v4  '; do
  run_evar get acme/app ${pair%% *}
  check_status 0 "get ${pair%% *}"
  check_out_exact "${pair#* }"$'\n'
done

begin_test 'get rejects corrupt files (exit 2) without echoing contents'
mkdir -p -- "$EVAR_HOME/acme/app/_"
printf 'CANARYVALUE\nsecond\n' > "$EVAR_HOME/acme/app/_/INTERIOR"
printf 'CANARYVALUE\rsecond\n' > "$EVAR_HOME/acme/app/_/INNERCR"
printf 'CANARYVALUE\xff\n' > "$EVAR_HOME/acme/app/_/BADUTF8"
printf 'CANARY\0VALUE\n' > "$EVAR_HOME/acme/app/_/WITHNUL"
for f in INTERIOR INNERCR BADUTF8 WITHNUL; do
  run_evar get acme/app $f
  check_status 2 "get $f"
  check_out_empty "stdout for $f"
  check_err_has "acme/app/_/$f"
  check_err_lacks CANARY
done

begin_test 'get refuses unsafe registry entries (exit 3)'
mkfile "$TEST_ROOT/outside/app/_/NAME" synthetic
mkdir -p -- "$EVAR_HOME/real/app/_" "$EVAR_HOME/acme/app/_/DIRVAR"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/linkorg"
ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/acme/app/_/LINKVAR"
/usr/bin/mkfifo "$EVAR_HOME/acme/app/_/FIFOVAR"
for args in 'linkorg/app NAME' 'acme/app LINKVAR' 'acme/app DIRVAR' 'acme/app FIFOVAR'; do
  run_evar get ${=args}
  check_status 3 "get $args"
  check_out_empty "stdout of get $args"
  check_err_has 'evar: '
done
if is_root; then
  skip_test 'running as root; unreadable-file case needs enforced permissions'
else
  print -r -- v > "$EVAR_HOME/acme/app/_/NOPERM"
  /bin/chmod 000 "$EVAR_HOME/acme/app/_/NOPERM"
  run_evar get acme/app NOPERM
  check_status 3 'unreadable file'
  /bin/chmod 600 "$EVAR_HOME/acme/app/_/NOPERM"
fi

begin_test 'get never creates the registry'
run_evar get acme/app NAME
check_status 1
check_no_path "$EVAR_HOME"
run_evar_raw -u EVAR_HOME -u XDG_CONFIG_HOME HOME="$TEST_HOME" -- get acme/app NAME
check_status 1
check_no_path "$TEST_HOME/.config"

# ---- Phase 5: exists -------------------------------------------------------

begin_test 'exists with a variable: 0 if present, 1 if not, silent either way'
run_evar set acme/app NAME v
run_evar exists acme/app NAME
check_status 0
check_out_empty
check_err_empty
run_evar exists acme/app/_ NAME
check_status 0 'explicit _'
for args in 'acme/app OTHER' 'acme/app/dev NAME' 'acme/nomod NAME' 'nobody/app NAME'; do
  run_evar exists ${=args}
  check_status 1 "exists $args"
  check_out_empty "stdout of exists $args"
  check_err_empty "stderr of exists $args"
done

begin_test 'exists is exact-case, silently'
mkfile "$EVAR_HOME/Acme/App/Dev/Name" v
for args in 'acme/App/Dev Name' 'Acme/app/Dev Name' 'Acme/App/dev Name' 'Acme/App/Dev NAME' 'ACME/App/Dev'; do
  run_evar exists ${=args}
  check_status 1 "exists $args"
  check_err_empty
done
run_evar exists Acme/App/Dev Name
check_status 0
run_evar exists Acme/App/Dev
check_status 0 'scope form'

begin_test 'exists without a variable: true only if the scope holds a variable file'
run_evar set acme/app NAME v
run_evar set acme/app/dev OTHER v
for args in 'acme/app' 'acme/app/_' 'acme/app/dev'; do
  run_evar exists $args
  check_status 0 "exists $args"
  check_out_empty
  check_err_empty
done
for args in 'acme/app/prod' 'acme/other' 'nobody/app'; do
  run_evar exists $args
  check_status 1 "exists $args"
  check_err_empty "stderr of exists $args"
done

begin_test 'exists: an empty scope directory, or one holding only junk, is not a scope'
mkdir -p -- "$EVAR_HOME/acme/empty/_" "$EVAR_HOME/acme/junk/_"
for junk in .DS_Store .evar-write.ABC123 notes.txt NAME.tmp 1bad CON nul.txt; do
  : > "$EVAR_HOME/acme/junk/_/$junk"
done
for args in 'acme/empty' 'acme/junk'; do
  run_evar exists $args
  check_status 1 "exists $args"
  check_err_empty
done
: > "$EVAR_HOME/acme/junk/_/REAL"
run_evar exists acme/junk
check_status 0 'a valid variable file among the junk'

begin_test 'exists reports presence without validating contents'
mkdir -p -- "$EVAR_HOME/acme/app/_"
printf 'a\nb\n' > "$EVAR_HOME/acme/app/_/BADVALUE"
run_evar exists acme/app BADVALUE
check_status 0
run_evar exists acme/app
check_status 0

begin_test 'exists treats unsafe entries as errors, never as missing (exit 3)'
mkfile "$TEST_ROOT/outside/app/_/NAME" synthetic
mkdir -p -- "$EVAR_HOME/acme/app/_/DIRVAR" "$EVAR_HOME/acme/mixed/_"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/linkorg"
ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/acme/app/_/LINKVAR"
/usr/bin/mkfifo "$EVAR_HOME/acme/app/_/FIFOVAR"
for args in 'linkorg/app NAME' 'linkorg/app' 'acme/app LINKVAR' 'acme/app DIRVAR' 'acme/app FIFOVAR' 'acme/app'; do
  run_evar exists ${=args}
  check_status 3 "exists $args"
  check_out_empty
  check_err_has 'evar: '
done
# An unsafe sibling is an error even when a valid variable also exists (and sorts first).
: > "$EVAR_HOME/acme/mixed/_/AAA"
ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/acme/mixed/_/ZZZ"
run_evar exists acme/mixed
check_status 3 'unsafe sibling after a valid variable'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkfile "$EVAR_HOME/acme/locked/_/NAME" v
  /bin/chmod 000 "$EVAR_HOME/acme/locked/_"
  run_evar exists acme/locked
  check_status 3 'unreadable scope directory'
  run_evar exists acme/locked NAME
  check_status 3 'unreadable scope directory with variable'
  /bin/chmod 700 "$EVAR_HOME/acme/locked/_"
fi

begin_test 'exists argument errors are exit 1 with a message; nothing is created'
typeset -a BAD_EXISTS_ARGS=('' 'acme' 'acme/app NAME extra' '--force acme/app' 'a//b' 'a/b/c/d' 'con/app' 'acme/app 1BAD' 'acme/app CON')
for args in "${BAD_EXISTS_ARGS[@]}"; do
  run_evar exists ${=args}
  check_status 1 "exists $args"
  check_out_empty
  check_err_has 'evar: '
  check_no_path "$EVAR_HOME"
done

begin_test 'exists --help prints help and exits 0; exists never creates the registry'
run_evar exists --help
check_status 0
[[ $OUT == 'Usage: evar exists'* ]] && (( ++T_PASS )) || t_fail 'exists --help does not start with its usage line'
run_evar exists acme/app NAME
check_status 1
check_no_path "$EVAR_HOME"

# ---- Phase 5: unset --------------------------------------------------------

begin_test 'unset deletes the variable silently and prunes every empty directory above it'
run_evar set acme/app NAME v
run_evar unset acme/app NAME
check_status 0
check_out_empty
check_err_empty
check_no_path "$EVAR_HOME/acme"
check_path "$EVAR_HOME"
run_evar get acme/app NAME
check_status 1 'get after unset'
run_evar exists acme/app
check_status 1 'exists after unset'

begin_test 'unset prunes only what is empty'
run_evar set acme/app A 1
run_evar set acme/app B 2
run_evar set acme/app/dev A 3
run_evar set acme/other A 4
run_evar unset acme/app A
check_status 0
check_no_path "$EVAR_HOME/acme/app/_/A"
check_path "$EVAR_HOME/acme/app/_/B"
run_evar unset acme/app B
check_no_path "$EVAR_HOME/acme/app/_"
check_path "$EVAR_HOME/acme/app/dev/A"
run_evar unset acme/app/dev A
check_no_path "$EVAR_HOME/acme/app"
check_path "$EVAR_HOME/acme/other/_/A"
check_path "$EVAR_HOME/acme"
run_evar unset acme/other A
check_no_path "$EVAR_HOME/acme"
check_path "$EVAR_HOME"

begin_test 'unset: omitted and explicit _ are the same slot'
run_evar set acme/app NAME v
run_evar unset acme/app/_ NAME
check_status 0
check_no_path "$EVAR_HOME/acme"

begin_test 'unset of a missing variable is exit 1; -f makes it exit 0'
run_evar set acme/app KEEP v
for args in 'acme/app OTHER' 'acme/app/dev KEEP' 'acme/nomod KEEP' 'nobody/app KEEP'; do
  run_evar unset ${=args}
  check_status 1 "unset $args"
  check_out_empty
  check_err_has 'evar: not found:'
  for opt in -f --force; do
    run_evar unset $opt ${=args}
    check_status 0 "unset $opt $args"
    check_out_empty
    check_err_empty
  done
done
run_evar unset acme/app KEEP -f
check_status 0 'option after the operands'
check_no_path "$EVAR_HOME/acme"
rm -rf -- "$EVAR_HOME"
run_evar unset acme/app KEEP
check_status 1 'absent registry'
run_evar unset -f acme/app KEEP
check_status 0 'absent registry with -f'
check_no_path "$EVAR_HOME"

begin_test 'unset is exact-case: a case-only match is missing and nothing is deleted'
mkfile "$EVAR_HOME/Acme/App/Dev/Name" v
for args in 'acme/App/Dev Name' 'Acme/app/Dev Name' 'Acme/App/dev Name' 'Acme/App/Dev NAME'; do
  run_evar unset ${=args}
  check_status 1 "unset $args"
  check_err_has 'match case exactly'
  run_evar unset -f ${=args}
  check_status 0 "unset -f $args"
  check_path "$EVAR_HOME/Acme/App/Dev/Name"
done
run_evar unset Acme/App/Dev Name
check_status 0
check_no_path "$EVAR_HOME/Acme"

begin_test 'unset never prunes a directory that still holds anything, hidden files included'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
mkfile "$EVAR_HOME/acme/app/_/.DS_Store" x
run_evar unset acme/app NAME
check_status 0
check_no_path "$EVAR_HOME/acme/app/_/NAME"
check_path "$EVAR_HOME/acme/app/_/.DS_Store"
mkfile "$EVAR_HOME/acme/app/dev/NAME" v
mkfile "$EVAR_HOME/acme/app/dev/.evar-write.LEFTOV" x
run_evar unset acme/app/dev NAME
check_status 0
check_path "$EVAR_HOME/acme/app/dev/.evar-write.LEFTOV"

begin_test 'unset can remove a corrupt variable file'
mkdir -p -- "$EVAR_HOME/acme/app/_"
printf 'CANARY\0\nsecond\n' > "$EVAR_HOME/acme/app/_/BAD"
run_evar unset acme/app BAD
check_status 0
check_no_path "$EVAR_HOME/acme"

begin_test 'unset refuses unsafe entries (exit 3), even with -f, and deletes nothing'
mkfile "$TEST_ROOT/outside/app/_/NAME" synthetic
mkdir -p -- "$EVAR_HOME/acme/app/_/DIRVAR"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/linkorg"
ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/acme/app/_/LINKVAR"
for args in 'linkorg/app NAME' 'acme/app LINKVAR' 'acme/app DIRVAR'; do
  for opt in '' -f; do
    run_evar unset $opt ${=args}
    check_status 3 "unset $opt $args"
    check_out_empty
  done
done
check_path "$TEST_ROOT/outside/app/_/NAME"
check_path "$EVAR_HOME/acme/app/_/LINKVAR"
check_path "$EVAR_HOME/acme/app/_/DIRVAR"

begin_test 'unset reports an undeletable file as an I/O error (exit 3)'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkfile "$EVAR_HOME/acme/app/_/NAME" keep
  /bin/chmod 500 "$EVAR_HOME/acme/app/_"
  run_evar unset acme/app NAME
  check_status 3
  /bin/chmod 700 "$EVAR_HOME/acme/app/_"
  check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'keep\n'
fi

begin_test 'unset argument errors are exit 1 and change nothing'
run_evar set acme/app KEEP v
typeset -a BAD_UNSET_ARGS=('' 'acme/app' 'acme/app KEEP extra' '--stdin acme/app KEEP' '--no-newline acme/app KEEP'
  'a KEEP' 'a//b KEEP' 'con/app KEEP' 'acme/app 1BAD' 'acme/app CON')
for args in "${BAD_UNSET_ARGS[@]}"; do
  run_evar unset ${=args}
  check_status 1 "unset $args"
  check_out_empty
  check_path "$EVAR_HOME/acme/app/_/KEEP"
done
run_evar unset --help
check_status 0
[[ $OUT == 'Usage: evar unset'* ]] && (( ++T_PASS )) || t_fail 'unset --help does not start with its usage line'

# ---- Phase 5: list ---------------------------------------------------------

begin_test 'list on an empty or absent registry succeeds with no output'
run_evar list
check_status 0
check_out_empty
check_err_empty
check_no_path "$EVAR_HOME"
mkdir -p -- "$EVAR_HOME"
run_evar list
check_status 0
check_out_empty

# Scope listings print full org/module/version paths, sorted bytewise as whole
# lines (the same order as LC_ALL=C sort), with an explicit _ for the default.
typeset -a LIST_SCOPES=(
  acme/app/_ acme/app/dev acme/app/prod acme/app-x/_ acme/web/_ acme/web/v1-dev
  zeta/tool/_ a/x/_ a-b/x/_ a.b/x/_ a_b/x/_ B/x/_ 9lives/m/_ acme/Zed/_
)
seed_scopes() {
  local s
  for s in "${LIST_SCOPES[@]}"; do
    mkfile "$EVAR_HOME/$s/VAR" "v"
  done
}

begin_test 'list with no argument prints every scope, normalized and bytewise sorted'
seed_scopes
run_evar list
check_status 0
check_err_empty
expected=$(print -rl -- "${LIST_SCOPES[@]}" | LC_ALL=C /usr/bin/sort)
check_eq "$OUT" "$expected" 'scope listing order and content'
[[ ${${(f)OUT}[1]} == 9lives/m/_ ]] && (( ++T_PASS )) || t_fail 'digits should sort before letters'

begin_test 'list <org> and list <org>/<module> print full scope paths (D1)'
seed_scopes
run_evar list acme
check_status 0
check_eq "$OUT" "$(print -rl -- acme/Zed/_ acme/app/_ acme/app/dev acme/app/prod acme/app-x/_ acme/web/_ acme/web/v1-dev | LC_ALL=C /usr/bin/sort)" 'list acme'
check_eq "${${(f)OUT}[2]}" 'acme/app-x/_' 'whole-line order puts acme/app-x/_ before acme/app/_'
run_evar list acme/app
check_eq "$OUT" "$(print -rl -- acme/app/_ acme/app/dev acme/app/prod)" 'list acme/app'
run_evar list acme/web
check_eq "$OUT" "$(print -rl -- acme/web/_ acme/web/v1-dev)" 'list acme/web'
run_evar list zeta
check_eq "$OUT" 'zeta/tool/_'

begin_test 'list output round-trips into other commands'
seed_scopes
run_evar list
for scope in ${(f)OUT}; do
  run_evar exists $scope
  check_status 0 "exists $scope"
  run_evar list $scope
  check_status 0 "list $scope"
  check_eq "$OUT" 'VAR=v' "list $scope"
  run_evar list
done

begin_test 'list <scope> prints VAR=VALUE sorted by variable name, bytewise'
# No two names differ only by case, so the fixture is valid on any filesystem.
typeset -a VARS=(B A _X A1 A_B Z9 z0 _ ab abc MixedCase LOG_LEVEL SERVER_PORT Alpha)
for v in "${VARS[@]}"; do
  mkfile "$EVAR_HOME/acme/app/dev/$v" "val-$v"
done
run_evar list acme/app/dev
check_status 0
check_err_empty
expected=$(for v in $(print -rl -- "${VARS[@]}" | LC_ALL=C /usr/bin/sort); do print -r -- "$v=val-$v"; done)
check_eq "$OUT" "$expected" 'variable listing'
lines=("${(f)OUT}")
# Sorting is by variable name, not by the whole line: A sorts before A1 even
# though "A1=" < "A=" as raw bytes.
check_eq "$lines[1]" 'A=val-A' 'A sorts before A1 and A_B'
check_eq "${lines[(i)B=*]}" 5 'B follows A, A1, A_B and Alpha'
(( ${lines[(i)Z9=*]} < ${lines[(i)_=*]} && ${lines[(i)_=*]} < ${lines[(i)_X=*]} && ${lines[(i)_X=*]} < ${lines[(i)ab=*]} )) &&
  (( ++T_PASS )) || t_fail 'expected uppercase < _ < _X < lowercase'

begin_test 'list <scope> keeps values verbatim; the first = is the delimiter'
typeset -a LIST_VALUES=('' 'a=b=c' 'with space' '  padded  ' '-leading' '--' "it's" '"q"' '$(touch CANARY)' '`touch CANARY`'
  '$HOME' '*' '[a-z]' ';|&' '\n' '%s' 'é' '日本語' '😀' '=')
i=0
for v in "${LIST_VALUES[@]}"; do
  run_evar set -- acme/app/dev "V$(( ++i ))" "$v"
done
run_evar list acme/app/dev
check_status 0
check_no_path "$PWD/CANARY"
i=0
for v in "${LIST_VALUES[@]}"; do
  line="V$(( ++i ))=$v"
  [[ $'\n'$OUT$'\n' == *$'\n'"$line"$'\n'* ]] && (( ++T_PASS )) || t_fail "list lacks the exact line ${(qq)line}"
done

begin_test 'list <org>/<module> does not include the default slot variables'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
run_evar list acme/app
check_out 'acme/app/_'
run_evar list acme/app/_
check_out 'NAME=v'

begin_test 'list reports an explicit prefix with nothing beneath it as exit 1 (D2)'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
mkdir -p -- "$EVAR_HOME/acme/emptymod/_" "$EVAR_HOME/lonely/app/_"
for args in nobody acme/nomod acme/app/prod acme/emptymod acme/emptymod/_ lonely lonely/app; do
  run_evar list $args
  check_status 1 "list $args"
  check_out_empty "stdout of list $args"
  check_err_has 'evar: '
done
rm -rf -- "$EVAR_HOME"
run_evar list acme
check_status 1 'explicit prefix on an absent registry'
check_no_path "$EVAR_HOME"

begin_test 'list is exact-case and explains a case-only mismatch'
mkfile "$EVAR_HOME/Acme/App/Dev/NAME" v
for args in acme ACME/App Acme/app Acme/App/dev; do
  run_evar list $args
  check_status 1 "list $args"
  check_err_has 'match case exactly'
done
run_evar list Acme/App/Dev
check_out 'NAME=v'

begin_test 'list ignores entries that are not valid identifiers or are hidden'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
: > "$EVAR_HOME/.DS_Store"
: > "$EVAR_HOME/acme/.DS_Store"
: > "$EVAR_HOME/acme/app/.DS_Store"
: > "$EVAR_HOME/acme/app/_/.DS_Store"
: > "$EVAR_HOME/acme/app/_/.evar-write.ABC123"
: > "$EVAR_HOME/acme/app/_/NAME.tmp"
: > "$EVAR_HOME/acme/app/_/notes.txt"
: > "$EVAR_HOME/acme/app/_/1bad"
: > "$EVAR_HOME/acme/app/_/CON"
mkdir -p -- "$EVAR_HOME/.hidden/x/_" "$EVAR_HOME/bad name/x/_" "$EVAR_HOME/con/x/_" "$EVAR_HOME/acme.dir./x/_" "$EVAR_HOME/acme/_hidden/_"
: > "$EVAR_HOME/bad name/x/_/V"
: > "$EVAR_HOME/con/x/_/V"
for args in '' acme acme/app acme/app/_; do
  run_evar list $args
  check_status 0 "list $args"
  check_err_empty
done
run_evar list
check_out 'acme/app/_'
run_evar list acme/app/_
check_out 'NAME=v'

begin_test 'list skips scopes that hold no variable file'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
mkdir -p -- "$EVAR_HOME/acme/app/dev" "$EVAR_HOME/acme/other/_"
run_evar list
check_out 'acme/app/_'
run_evar list acme/app
check_out 'acme/app/_'

begin_test 'list fails on corrupt content (exit 2) and never prints partial results'
mkdir -p -- "$EVAR_HOME/acme/app/_"
printf 'good\n' > "$EVAR_HOME/acme/app/_/AAA"
printf 'CANARYVALUE\nsecond\n' > "$EVAR_HOME/acme/app/_/BBB"
printf 'good\n' > "$EVAR_HOME/acme/app/_/CCC"
run_evar list acme/app/_
check_status 2
check_out_empty 'no partial output'
check_err_has 'acme/app/_/BBB'
check_err_lacks CANARYVALUE
printf 'CANARY\xff\n' > "$EVAR_HOME/acme/app/_/BBB"
run_evar list acme/app/_
check_status 2 'invalid UTF-8'
check_out_empty
printf 'CANARY\0x\n' > "$EVAR_HOME/acme/app/_/BBB"
run_evar list acme/app/_
check_status 2 'NUL'
check_out_empty

begin_test 'list refuses unsafe entries that look like registry names (exit 3), with no partial output'
mkfile "$TEST_ROOT/outside/app/_/NAME" synthetic
mkdir -p -- "$EVAR_HOME/acme/app/_" "$EVAR_HOME/acme/mod/_"
: > "$EVAR_HOME/acme/app/_/AAA"
ln -s "$TEST_ROOT/outside/app/_/NAME" "$EVAR_HOME/acme/app/_/ZZZ"
for args in acme/app/_ acme/app acme ''; do
  run_evar list $args
  check_status 3 "list $args (symlinked variable)"
  check_out_empty
done
/bin/rm -f -- "$EVAR_HOME/acme/app/_/ZZZ"
ln -s "$TEST_ROOT/outside" "$EVAR_HOME/zorg"
for args in '' zorg; do
  run_evar list $args
  check_status 3 "list $args (symlinked org)"
  check_out_empty
done
/bin/rm -f -- "$EVAR_HOME/zorg"
: > "$EVAR_HOME/README.md"
run_evar list
check_status 3 'regular file where an org directory is expected'
/bin/rm -f -- "$EVAR_HOME/README.md"
/usr/bin/mkfifo "$EVAR_HOME/acme/app/_/FIFOVAR"
run_evar list acme/app/_
check_status 3 'fifo variable'

begin_test 'list reports an unreadable directory as an I/O error (exit 3)'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkfile "$EVAR_HOME/acme/app/_/NAME" v
  /bin/chmod 000 "$EVAR_HOME/acme/app"
  run_evar list
  check_status 3 'list with an unreadable module directory'
  run_evar list acme/app/_
  check_status 3 'list into an unreadable module directory'
  /bin/chmod 700 "$EVAR_HOME/acme/app"
fi

begin_test 'list is read-only'
seed_scopes
before=$(/usr/bin/find "$EVAR_HOME" | /usr/bin/sort)
run_evar list
run_evar list acme/app
run_evar list acme/app/_
run_evar list nobody
check_eq "$(/usr/bin/find "$EVAR_HOME" | /usr/bin/sort)" "$before" 'registry after list'

begin_test 'list argument errors are exit 1 with a message'
typeset -a BAD_LIST_ARGS=('acme/app extra' 'a//b' '/acme' 'acme/' 'a/b/c/d' 'con' 'acme./app' 'a/b/_x' '--force' '--stdin')
for args in "${BAD_LIST_ARGS[@]}"; do
  run_evar list ${=args}
  check_status 1 "list $args"
  check_out_empty
  check_err_has 'evar: '
done
run_evar list ''
check_status 1 'an explicitly empty argument'
run_evar list -- acme
check_status 1 'list -- <org> is a positional (and acme is absent here)'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
run_evar list -- acme
check_status 0
run_evar list --help
check_status 0
[[ $OUT == 'Usage: evar list'* ]] && (( ++T_PASS )) || t_fail 'list --help does not start with its usage line'

# ---- Phase 6: concurrency and robustness -----------------------------------
# evar takes no locks: the last writer wins. What must always hold is that a
# reader or writer sees a complete value, never a torn file, and that no
# temporary file survives a completed run.

begin_test 'concurrent set of one variable leaves exactly one of the written values'
x=''
for round in 1 2 3; do
  bg_reset
  rm -rf -- "$EVAR_HOME"
  typeset -a WRITTEN=()
  for n in {1..16}; do
    v="writer-$n-${(l:300::x:)x}"
    WRITTEN+=("$v")
    bg_evar "w$n" set acme/app NAME "$v"
  done
  wait
  for n in {1..16}; do
    check_eq "$(bg_status w$n)" 0 "round $round: writer $n exit status ($(<$TEST_ROOT/bg.w$n.err))"
  done
  final=$(<"$EVAR_HOME/acme/app/_/NAME")
  [[ ${WRITTEN[(Ie)$final]} -gt 0 ]] && (( ++T_PASS )) || t_fail "round $round: final value is not one of the written values: ${(q)final[1,40]}"
  check_mode "$EVAR_HOME/acme/app/_/NAME" 600
  check_no_temp "$EVAR_HOME"
  check_eq "$(/usr/bin/find "$EVAR_HOME/acme/app/_" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" 1 'files in the scope directory'
done
run_evar get acme/app NAME
check_status 0 'get after the race'

begin_test 'concurrent creation of different variables in a brand-new registry'
for round in 1 2 3 4 5; do
  bg_reset
  rm -rf -- "$EVAR_HOME"
  for n in {1..16}; do
    bg_evar "c$n" set acme/app "V$n" "value-$n"
  done
  wait
  for n in {1..16}; do
    check_eq "$(bg_status c$n)" 0 "round $round: creator $n exit status ($(<$TEST_ROOT/bg.c$n.err))"
    check_file_bytes "$EVAR_HOME/acme/app/_/V$n" "value-$n"$'\n' "round $round: variable V$n"
  done
  for p in "$EVAR_HOME" "$EVAR_HOME/acme" "$EVAR_HOME/acme/app" "$EVAR_HOME/acme/app/_"; do
    check_mode "$p" 700
  done
  check_no_temp "$EVAR_HOME"
done

begin_test 'entry_kind re-classifies when an entry appears between its checks'
mkdir -p -- "$EVAR_HOME/acme"
FLIP='functions -c kind_once real_kind_once
typeset -gi calls=0
kind_once() { if (( calls++ == 0 )); then KIND_ONCE=none; else real_kind_once "$@"; fi }
entry_kind "$1"; print -r -- "kind=$ENTRY_KIND calls=$calls"'
run_snippet "$FLIP" "$EVAR_HOME/acme"
check_status 0
check_out 'kind=dir calls=4'

begin_test 'entry_kind reports a path that is absent, and one it cannot examine'
run_snippet 'entry_kind "$1"; print -r -- "$ENTRY_KIND"' "$EVAR_HOME/nothing/here"
check_out missing
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  mkdir -p -- "$EVAR_HOME/locked/inner"
  /bin/chmod 000 "$EVAR_HOME/locked"
  run_snippet 'entry_kind "$1"; print -r -- "$ENTRY_KIND"' "$EVAR_HOME/locked/inner"
  check_out unknown
  /bin/chmod 700 "$EVAR_HOME/locked"
fi

begin_test 'concurrent set and unset of one variable: set succeeds or fails with 3, state stays consistent'
bg_reset
( for n in {1..40}; do
    evar_isolated set acme/app NAME "value-$n" > /dev/null 2>> "$TEST_ROOT/bg.setloop.err" < /dev/null
    print -r -- $? >> "$TEST_ROOT/bg.setloop.codes"
  done ) &
( for n in {1..40}; do
    evar_isolated unset -f acme/app NAME > /dev/null 2>> "$TEST_ROOT/bg.unsetloop.err" < /dev/null
    print -r -- $? >> "$TEST_ROOT/bg.unsetloop.codes"
  done ) &
wait
for code in ${(f)"$(<$TEST_ROOT/bg.setloop.codes)"}; do
  [[ $code == (0|3) ]] && (( ++T_PASS )) || t_fail "set exited with $code (expected 0 or 3)"
done
for code in ${(f)"$(<$TEST_ROOT/bg.unsetloop.codes)"}; do
  [[ $code == (0|3) ]] && (( ++T_PASS )) || t_fail "unset -f exited with $code (expected 0 or 3)"
done
check_no_temp "$EVAR_HOME"
if [[ -e $EVAR_HOME/acme/app/_/NAME ]]; then
  [[ $(<"$EVAR_HOME/acme/app/_/NAME") == value-<1-40> ]] && (( ++T_PASS )) || t_fail 'surviving file is not a complete written value'
fi
leftovers=$(/usr/bin/find "$EVAR_HOME" -mindepth 1 \( -type f ! -name NAME \) 2>/dev/null)
check_eq "$leftovers" '' 'unexpected files after the race'
run_evar list
check_status 0 'registry is still listable after the race'

begin_test 'readers never observe a torn or invalid value while a writer replaces it'
x=''
VALUE_A=${(l:3000::A:)x}
VALUE_B=${(l:3000::B:)x}
run_evar set acme/app NAME "$VALUE_A"
bg_reset
( for n in {1..20}; do
    evar_isolated set acme/app NAME "$VALUE_B" < /dev/null > /dev/null 2>&1
    print -r -- $? >> "$TEST_ROOT/bg.writer.codes"
    evar_isolated set acme/app NAME "$VALUE_A" < /dev/null > /dev/null 2>&1
    print -r -- $? >> "$TEST_ROOT/bg.writer.codes"
  done; : > "$TEST_ROOT/bg.writer.done" ) &
reads=0 overlapping=0 bad=0
while [[ ! -e $TEST_ROOT/bg.writer.done ]] && (( reads < 100 )); do
  got=$(evar_isolated get acme/app NAME < /dev/null 2> "$TEST_ROOT/bg.reader.err")
  rc=$?
  (( ++reads ))
  # A read that finished while the writer loop was still running overlapped it.
  [[ -e $TEST_ROOT/bg.writer.done ]] || (( ++overlapping ))
  if (( rc != 0 )) || [[ $got != $VALUE_A && $got != $VALUE_B ]]; then
    (( ++bad ))
    print -u2 -r -- "reader saw rc=$rc stderr=$(<$TEST_ROOT/bg.reader.err)"
  fi
done
wait
check_eq "$bad" 0 "invalid reads out of $reads"
(( overlapping >= 3 )) && (( ++T_PASS )) || t_fail "only $overlapping reads overlapped the writer (need at least 3)"
check_eq "$(/usr/bin/sort -u "$TEST_ROOT/bg.writer.codes" | /usr/bin/tr '\n' ' ')" '0 ' 'every replacement succeeded'
check_eq "$(/usr/bin/wc -l < "$TEST_ROOT/bg.writer.codes" | /usr/bin/tr -d ' ')" 40 'replacements performed'
check_no_temp "$EVAR_HOME"

# A process killed with SIGKILL between mktemp and mv leaves one hidden temp
# file. The hook below kills the process right after the temp file is written.
KILL_AFTER_WRITE='functions -c emit real_emit
emit() { real_emit "$@"; kill -KILL $$ }
registry_root; write_var_file "$@"'

begin_test 'a write killed before the rename leaves only an ignored hidden temp file'
run_snippet "$KILL_AFTER_WRITE" acme app _ NAME interrupted
check_eq "$STATUS" 137 'the process was killed'
temps=("$EVAR_HOME"/acme/app/_/.evar-write.*(N))
check_eq "${#temps}" 1 'one temporary file remains'
check_mode "${temps[1]}" 600
check_no_path "$EVAR_HOME/acme/app/_/NAME"
run_evar list
check_status 0
check_out_empty 'list ignores the temporary file'
run_evar exists acme/app
check_status 1 'exists ignores the temporary file'
run_evar get acme/app NAME
check_status 1
run_evar set acme/app NAME recovered
check_status 0 'a later set works'
check_file_bytes "$EVAR_HOME/acme/app/_/NAME" $'recovered\n'

begin_test 'a killed overwrite leaves the old value intact'
run_evar set acme/app NAME original
run_snippet "$KILL_AFTER_WRITE" acme app _ NAME replacement
check_eq "$STATUS" 137 'the process was killed'
run_evar get acme/app NAME
check_out original
run_evar list acme/app/_
check_out 'NAME=original'

begin_test 'the leftover temp file keeps its directory from being pruned (documented limitation)'
run_snippet "$KILL_AFTER_WRITE" acme app _ NAME interrupted
run_evar set acme/app OTHER v
run_evar unset acme/app OTHER
check_status 0
check_path "$EVAR_HOME/acme/app/_"

begin_test 'SIGTERM while waiting on stdin ends evar promptly and leaves no orphaned reader'
# Holding the FIFO open read-write keeps evar blocked reading stdin without an
# EOF. evar is started directly (not through a subshell) so $! is its own PID;
# only that PID is ever signaled.
/usr/bin/mkfifo "$TEST_ROOT/blocker"
exec 7<> "$TEST_ROOT/blocker"
/usr/bin/env -u XDG_CONFIG_HOME HOME="$TEST_HOME" EVAR_HOME="$EVAR_HOME" \
  zsh "$EVAR_SCRIPT" set acme/app NAME --stdin < "$TEST_ROOT/blocker" > /dev/null 2>&1 7>&- &
pid=$!
/bin/sleep 0.6
# Reading stdin happens in evar's own process, so there is no child (cat or a
# subshell) that could outlive it.
check_eq "$(/usr/bin/pgrep -P $pid 2> /dev/null)" '' 'child processes of evar while it waits for stdin'
kill -TERM $pid
for _ in {1..30}; do
  kill -0 $pid 2> /dev/null || break
  /bin/sleep 0.1
done
if kill -0 $pid 2> /dev/null; then
  t_fail 'evar was still running 3s after SIGTERM'
  kill -KILL $pid
fi
wait $pid
check_eq $? 143 'exit status after SIGTERM (stdin still open)'
exec 7>&-
check_no_path "$EVAR_HOME"

begin_test 'SIGTERM inside the write window removes the temp file and exits 143'
TERM_AFTER_WRITE='trap cleanup_temp_files EXIT
functions -c emit real_emit
emit() { real_emit "$@"; kill -TERM $$ }
registry_root; write_var_file "$@"'
run_snippet "$TERM_AFTER_WRITE" acme app _ NAME interrupted
check_eq "$STATUS" 143 'exit status'
check_no_temp "$EVAR_HOME"
check_no_path "$EVAR_HOME/acme/app/_/NAME"

begin_test 'SIGINT and SIGHUP inside the write window also clean up'
for sig in INT HUP; do
  rm -rf -- "$EVAR_HOME"
  run_snippet "trap cleanup_temp_files EXIT
functions -c emit real_emit
emit() { real_emit \"\$@\"; kill -$sig \$\$ }
registry_root; write_var_file \"\$@\"" acme app _ NAME interrupted
  [[ $sig == INT ]] && expected=130 || expected=129
  check_eq "$STATUS" $expected "exit status after SIG$sig"
  check_no_temp "$EVAR_HOME"
done

begin_test 'cleanup_temp_files removes every registered temp file and forgets them'
print -r -- x > "$TEST_ROOT/tmp1"
print -r -- x > "$TEST_ROOT/tmp2"
run_snippet 'EVAR_TEMP_FILES=("$1" "$2"); cleanup_temp_files; print -r -- "left=${#EVAR_TEMP_FILES}"' "$TEST_ROOT/tmp1" "$TEST_ROOT/tmp2"
check_status 0
check_out 'left=0'
check_no_path "$TEST_ROOT/tmp1"
check_no_path "$TEST_ROOT/tmp2"

# A directory or file that vanishes mid-walk because of a concurrent unset is
# missing (not an I/O error); a real I/O failure is still exit 3.

begin_test 'list_dir treats a directory that vanished as empty'
mkdir -p -- "$EVAR_HOME"
run_snippet 'registry_root; list_dir "$REGISTRY_ROOT/gone"; print -r -- "rc=$? n=${#DIR_ENTRIES}"'
check_status 0
check_out 'rc=0 n=0'

begin_test 'resolve_chain treats an entry that vanishes before its type check as missing'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
VANISH='functions -c require_kind real_require_kind
require_kind() { /bin/rm -rf -- "$1"; real_require_kind "$@" }
registry_root; resolve_chain file acme app _ NAME; rc=$?
print -r -- "rc=$rc missing=$MISSING_SEGMENT count=$RESOLVED_COUNT"; exit $rc'
run_snippet "$VANISH"
check_status 1
check_out 'rc=1 missing=acme count=0'

begin_test 'read_var_file treats a file that vanishes before the read as missing'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
run_snippet 'functions -c validate_value_file real_validate_value_file
validate_value_file() { /bin/rm -f -- "$1"; real_validate_value_file "$@" }
registry_root; read_var_file acme app _ NAME; exit $?'
check_status 1
check_out_empty

begin_test 'scope_has_variable treats an entry that vanishes before its type check as missing'
mkfile "$EVAR_HOME/acme/app/_/NAME" v
run_snippet 'functions -c require_kind real_require_kind
require_kind() { /bin/rm -rf -- "$1"; real_require_kind "$@" }
registry_root; scope_has_variable "$REGISTRY_ROOT/acme/app/_"; exit $?'
check_status 1

# ---- Phase 6 follow-ups from review ----------------------------------------

begin_test 'a failed write to stdout is exit 3 with an evar: diagnostic, never a silent success'
run_evar set acme/app NAME value
mkdir -p -- "$EVAR_HOME/acme/app/_"
for args in '--version' '--help' 'get acme/app NAME' 'get -n acme/app NAME' 'list' 'list acme/app/_' 'get --help'; do
  STDOUT_CLOSED=1
  run_evar ${=args}
  check_status 3 "evar $args >&-"
  check_err_has 'evar: cannot write to standard output'
done

begin_test 'closed stdin is exit 3 with only an evar: diagnostic'
STDIN_FILE=CLOSED
run_evar set acme/app NAME --stdin
check_status 3
[[ $ERR == 'evar: '* && $ERR != *$'\n'* ]] && (( ++T_PASS )) || t_fail "expected a single evar: line, got ${(q)ERR}"
check_no_path "$EVAR_HOME"

begin_test 'a set rejected after a concurrent creator leaves no directories of its own behind'
CREATE_VARIANT='functions -c ensure_scope_dirs real_ensure_scope_dirs
ensure_scope_dirs() { /bin/mkdir -p -- "$REGISTRY_ROOT/acme"; real_ensure_scope_dirs "$@"; }
registry_root; write_var_file Acme App Dev NAME value'
if fs_case_insensitive; then
  run_snippet "$CREATE_VARIANT"
  check_status 1
  check_eq "$(/usr/bin/find "$EVAR_HOME" -mindepth 1 | /usr/bin/sort)" "$EVAR_HOME/acme" 'only the concurrent creator'"'"'s directory remains'
else
  skip_test 'needs a case-insensitive filesystem'
fi

begin_test 'dir_read_failed distinguishes a readable empty directory from an unreadable one'
mkdir -p -- "$EVAR_HOME/readable" "$EVAR_HOME/locked"
run_snippet 'dir_read_failed "$1"; print -r -- "rc=$?"' "$EVAR_HOME/readable"
check_out 'rc=1'
if is_root; then
  skip_test 'running as root; permissions are not enforced'
else
  /bin/chmod 000 "$EVAR_HOME/locked"
  run_snippet 'dir_read_failed "$1"; print -r -- "rc=$?"' "$EVAR_HOME/locked"
  check_out 'rc=0'
  /bin/chmod 700 "$EVAR_HOME/locked"
fi

begin_test 'list_dir does not believe an empty-looking directory whose read fails (exit 3)'
mkdir -p -- "$EVAR_HOME/empty"
run_snippet 'dir_read_failed() { return 0 }
registry_root; list_dir "$REGISTRY_ROOT/empty"; print -r -- "silently empty"'
check_status 3
check_out_empty
check_err_has "cannot read registry directory 'empty'"
run_snippet 'registry_root; list_dir "$REGISTRY_ROOT/empty"; print -r -- "n=${#DIR_ENTRIES}"'
check_out 'n=0'

# ---- Documentation agrees with the implementation --------------------------

REPO_ROOT=${EVAR_SCRIPT:h}
squeeze() { print -r -- "$1" | /usr/bin/tr -s ' \t\n' ' '; }

begin_test 'the documented command grammar matches the inline help'
typeset -a GRAMMAR=(
  'evar get [-n|--no-newline] [--] <org>/<module>[/<version>] <VAR>'
  'evar set [--] <org>/<module>[/<version>] <VAR> <VALUE>'
  'evar set <org>/<module>[/<version>] <VAR> --stdin'
  'evar unset [-f|--force] [--] <org>/<module>[/<version>] <VAR>'
  'evar exists [--] <org>/<module>[/<version>] [<VAR>]'
  'evar list [--] [<org>[/<module>[/<version>]]]'
)
README_TEXT=$(squeeze "$(<"$REPO_ROOT/README.md")")
SPEC_TEXT=$(squeeze "$(<"$REPO_ROOT/spec/SPEC.md")")
HELP_TEXT=''
for cmd in get set unset exists list; do
  run_evar $cmd --help
  HELP_TEXT+=" $(squeeze "$OUT")"
done
for line in "${GRAMMAR[@]}"; do
  [[ $README_TEXT == *"$line"* ]] && (( ++T_PASS )) || t_fail "README.md lacks the grammar line: $line"
  [[ $SPEC_TEXT == *"$line"* ]] && (( ++T_PASS )) || t_fail "spec/SPEC.md lacks the grammar line: $line"
  [[ $HELP_TEXT == *"$line"* ]] && (( ++T_PASS )) || t_fail "inline help lacks the grammar line: $line"
done

begin_test 'the documentation states the current version, exit codes and root rules'
run_evar --version
current=${OUT#evar }
CONTRIB_TEXT=$(squeeze "$(<"$REPO_ROOT/CONTRIBUTING.md")")
SECURITY_TEXT=$(squeeze "$(<"$REPO_ROOT/SECURITY.md")")
[[ $README_TEXT == *"\`$current\`"* ]] && (( ++T_PASS )) || t_fail "README.md does not mention the current version $current"
[[ $SPEC_TEXT == *"\`$current\`"* ]] && (( ++T_PASS )) || t_fail "spec/SPEC.md does not mention the current version $current"
for doc in README_TEXT SPEC_TEXT; do
  for code in '| 0 |' '| 1 |' '| 2 |' '| 3 |'; do
    [[ ${(P)doc} == *"$code"* ]] && (( ++T_PASS )) || t_fail "$doc lacks an exit-code row $code"
  done
  [[ ${(P)doc} == *'EVAR_HOME'* && ${(P)doc} == *'XDG_CONFIG_HOME'* ]] && (( ++T_PASS )) || t_fail "$doc does not describe the root derivation"
done
run_evar --help
for word in EVAR_HOME XDG_CONFIG_HOME; do
  [[ $OUT == *"$word"* ]] && (( ++T_PASS )) || t_fail "the inline help does not mention $word"
done
for suite in tests/lib.zsh tests/test-cli.zsh tests/test-validation.zsh; do
  [[ $CONTRIB_TEXT == *"zsh -n $suite"* ]] && (( ++T_PASS )) || t_fail "CONTRIBUTING.md does not list the syntax check for $suite"
  [[ $(squeeze "$(<"$REPO_ROOT/.github/workflows/ci.yml")") == *"zsh -n $suite"* ]] && (( ++T_PASS )) || t_fail "ci.yml does not run the syntax check for $suite"
  [[ $(squeeze "$(<"$REPO_ROOT/.github/copilot-instructions.md")") == *"zsh -n $suite"* ]] && (( ++T_PASS )) || t_fail "copilot-instructions.md does not list the syntax check for $suite"
done
for suite in tests/test-cli.zsh tests/test-validation.zsh; do
  [[ $CONTRIB_TEXT == *"zsh $suite"* ]] && (( ++T_PASS )) || t_fail "CONTRIBUTING.md does not list running $suite"
  [[ $(squeeze "$(<"$REPO_ROOT/.github/workflows/ci.yml")") == *"zsh $suite"* ]] && (( ++T_PASS )) || t_fail "ci.yml does not run $suite"
done

begin_test 'the documentation contains no leftover skeleton wording'
for stale in 'initial skeleton' 'not implemented yet' 'planned local-first' 'are still under design'; do
  for doc in README_TEXT SECURITY_TEXT CONTRIB_TEXT SPEC_TEXT; do
    [[ ${(P)doc} != *"$stale"* ]] && (( ++T_PASS )) || t_fail "$doc still contains: $stale"
  done
done

finish_suite 'CLI tests'
