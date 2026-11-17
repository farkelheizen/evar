# Shared harness for the evar test suites. Source it from a suite after
# setting EVAR_SCRIPT; do not execute it directly.
#
# Safety: every evar invocation runs through helpers that set an explicit
# temporary EVAR_HOME and a temporary HOME (and refuse to run without
# EVAR_HOME), and the suites run from a scratch working directory. The harness
# never reads or stats the user's real registry.

setopt no_unset pipe_fail
unsetopt err_exit
export LC_ALL=C

typeset -gi T_PASS=0 T_FAIL=0 T_SKIP=0 T_REG=0
typeset -g T_NAME='' STATUS=0 OUT='' ERR='' STDIN_FILE=/dev/null EVAR_HOME=''
typeset -gi STDOUT_CLOSED=0

[[ -n ${EVAR_SCRIPT-} && -f $EVAR_SCRIPT ]] || {
  print -u2 -r -- 'harness: EVAR_SCRIPT must name the evar script'
  exit 99
}

TEST_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/evar-test.XXXXXX") || {
  print -u2 -r -- 'harness: cannot create a temporary directory'
  exit 99
}
TEST_HOME=$TEST_ROOT/home
OUT_FILE=$TEST_ROOT/stdout
ERR_FILE=$TEST_ROOT/stderr
STDIN_TMP=$TEST_ROOT/stdin
/bin/mkdir -p -- "$TEST_HOME" "$TEST_ROOT/cwd"
# Run everything from a scratch directory so a regression that writes relative
# paths (for example by evaluating a stored value) cannot touch the repository.
cd "$TEST_ROOT/cwd" || exit 99

cleanup_tests() {
  [[ $TEST_ROOT == */evar-test.* && -d $TEST_ROOT ]] || return 0
  # Failure-injection tests chmod directories; restore access before removal.
  /bin/chmod -R u+rwx -- "$TEST_ROOT" 2>/dev/null
  /bin/rm -rf -- "$TEST_ROOT"
}
trap cleanup_tests EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- test bookkeeping ------------------------------------------------------

# begin_test <name>: names the test and points EVAR_HOME at a fresh, absent
# registry path inside the temporary root.
begin_test() {
  T_NAME=$1
  new_registry
  # Per-test scratch state: the symlink-target tree and the fake home/XDG dirs.
  /bin/rm -rf -- "$TEST_ROOT/outside" "$TEST_ROOT/xdg" "$TEST_HOME"
  /bin/mkdir -p -- "$TEST_HOME"
}

new_registry() {
  EVAR_HOME=$TEST_ROOT/registry.$(( ++T_REG ))
}

t_fail() {
  (( ++T_FAIL ))
  print -u2 -r -- "FAIL [$T_NAME]: $*"
}

skip_test() {
  (( ++T_SKIP ))
  print -r -- "SKIP [$T_NAME]: $*"
}

is_root() { (( EUID == 0 )) }

# Succeeds when the filesystem under TEST_ROOT ignores case in names.
fs_case_insensitive() {
  local probe=$TEST_ROOT/CaseProbe
  [[ -e $probe ]] || : > "$probe"
  [[ -e ${probe:h}/caseprobe ]]
}

# ---- running evar ----------------------------------------------------------

# run_evar_raw <env-args...> -- <evar-args...>
# Runs evar under /usr/bin/env with exactly the given environment edits.
# Captures STATUS, OUT/ERR (trailing newlines trimmed) and OUT_FILE/ERR_FILE
# (exact bytes). STDIN_FILE (a path, or CLOSED for a closed descriptor) and
# STDOUT_CLOSED are consumed and reset after each run.
run_evar_raw() {
  local -a envargs
  while (( $# )) && [[ $1 != -- ]]; do
    envargs+=("$1")
    shift
  done
  (( $# )) && shift
  (
    if [[ $STDIN_FILE == CLOSED ]]; then exec <&-; else exec < "$STDIN_FILE"; fi
    if (( STDOUT_CLOSED )); then exec >&-; else exec > "$OUT_FILE"; fi
    exec 2> "$ERR_FILE"
    exec /usr/bin/env "${envargs[@]}" zsh "$EVAR_SCRIPT" "$@"
  )
  STATUS=$?
  STDIN_FILE=/dev/null
  (( STDOUT_CLOSED )) && : > "$OUT_FILE"
  STDOUT_CLOSED=0
  OUT=$(<"$OUT_FILE")
  ERR=$(<"$ERR_FILE")
}

# run_evar <args...>: the normal entry point; refuses to run without EVAR_HOME.
run_evar() {
  if [[ -z ${EVAR_HOME-} ]]; then
    print -u2 -r -- 'harness: EVAR_HOME must be set before running evar'
    exit 99
  fi
  run_evar_raw -u XDG_CONFIG_HOME HOME="$TEST_HOME" EVAR_HOME="$EVAR_HOME" -- "$@"
}

# run_snippet_raw <env-args...> -- <code> [args...]: sources evar (which does
# not run main when sourced) in a fresh zsh under /usr/bin/env with exactly the
# given environment edits, then evals <code> with the remaining arguments as
# "$@". Test code only; evar itself never evals anything. STATUS/OUT/ERR as
# for run_evar.
run_snippet_raw() {
  local -a envargs
  while (( $# )) && [[ $1 != -- ]]; do
    envargs+=("$1")
    shift
  done
  (( $# )) && shift
  /usr/bin/env "${envargs[@]}" \
    zsh -c 'source "$1" || exit 98; code=$2; shift 2; eval "$code"' \
    evar-test "$EVAR_SCRIPT" "$@" \
    < "$STDIN_FILE" > "$OUT_FILE" 2> "$ERR_FILE"
  STATUS=$?
  STDIN_FILE=/dev/null
  OUT=$(<"$OUT_FILE")
  ERR=$(<"$ERR_FILE")
}

# run_snippet <code> [args...]: run_snippet_raw with the standard temporary
# environment; refuses to run without EVAR_HOME.
run_snippet() {
  if [[ -z ${EVAR_HOME-} ]]; then
    print -u2 -r -- 'harness: EVAR_HOME must be set before running evar'
    exit 99
  fi
  run_snippet_raw -u XDG_CONFIG_HOME HOME="$TEST_HOME" EVAR_HOME="$EVAR_HOME" -- "$@"
}

# run_fn <function> [args...]: calls one evar function via run_snippet.
run_fn() {
  run_snippet '"$@"' "$@"
}

# stdin_bytes <string>: the next run reads exactly these bytes on stdin.
stdin_bytes() {
  print -rn -- "$1" > "$STDIN_TMP"
  STDIN_FILE=$STDIN_TMP
}

# stdin_printf <format> [args...]: like stdin_bytes but through printf, so the
# format can carry NUL and arbitrary bytes.
stdin_printf() {
  printf "$@" > "$STDIN_TMP"
  STDIN_FILE=$STDIN_TMP
}

# ---- assertions ------------------------------------------------------------

check_eq() { # actual expected [label]
  if [[ $1 == "$2" ]]; then
    (( ++T_PASS ))
  else
    t_fail "${3:-value}: expected ${(q)2}, got ${(q)1}"
  fi
}

check_status() { # expected [label]
  if (( STATUS == $1 )); then
    (( ++T_PASS ))
  else
    t_fail "${2:-exit status}: expected $1, got $STATUS (stderr: ${(q)ERR})"
  fi
}

check_out() { # expected (trailing newlines ignored)
  check_eq "$OUT" "$1" "${2:-stdout}"
}

# Exact stdout bytes, including trailing newlines.
check_out_exact() { # expected [label]
  if print -rn -- "$1" | /usr/bin/cmp -s - "$OUT_FILE"; then
    (( ++T_PASS ))
  else
    t_fail "${2:-stdout bytes}: expected ${(q)1}, got ${(q)$(<"$OUT_FILE")}"
  fi
}

check_out_empty() {
  if [[ ! -s $OUT_FILE ]]; then
    (( ++T_PASS ))
  else
    t_fail "${1:-stdout}: expected empty, got ${(q)OUT}"
  fi
}

check_err_has() { # substring
  if [[ $ERR == *"$1"* ]]; then
    (( ++T_PASS ))
  else
    t_fail "stderr: expected to contain ${(q)1}, got ${(q)ERR}"
  fi
}

check_err_lacks() { # substring
  if [[ $ERR != *"$1"* && $OUT != *"$1"* ]]; then
    (( ++T_PASS ))
  else
    t_fail "output unexpectedly contains ${(q)1}"
  fi
}

check_err_empty() {
  if [[ ! -s $ERR_FILE ]]; then
    (( ++T_PASS ))
  else
    t_fail "stderr: expected empty, got ${(q)ERR}"
  fi
}

check_file_bytes() { # path expected-string [label]
  if [[ -f $1 ]] && print -rn -- "$2" | /usr/bin/cmp -s - "$1"; then
    (( ++T_PASS ))
  else
    t_fail "${3:-file bytes} ($1): expected ${(q)2}, got ${(q)$(<"$1" 2>/dev/null)}"
  fi
}

check_mode() { # path expected-octal
  local mode
  mode=$(/usr/bin/stat -f '%Lp' "$1" 2>/dev/null)
  check_eq "$mode" "$2" "mode of $1"
}

check_path() { # path (exists, including dangling symlinks)
  if [[ -e $1 || -L $1 ]]; then
    (( ++T_PASS ))
  else
    t_fail "expected path to exist: $1"
  fi
}

check_no_path() { # path
  if [[ ! -e $1 && ! -L $1 ]]; then
    (( ++T_PASS ))
  else
    t_fail "expected path to be absent: $1"
  fi
}

# No evar temporary files anywhere under a directory.
check_no_temp() { # dir
  local found
  found=$(/usr/bin/find "$1" -name '.evar-write.*' 2>/dev/null)
  check_eq "$found" '' "stray temporary files under $1"
}

# evar_isolated <evar-args...>: runs evar in the foreground with the standard
# temporary environment (for loops and background jobs). Never inherits the
# caller's HOME, XDG_CONFIG_HOME or EVAR_HOME.
evar_isolated() {
  if [[ -z ${EVAR_HOME-} ]]; then
    print -u2 -r -- 'harness: EVAR_HOME must be set before running evar'
    exit 99
  fi
  /usr/bin/env -u XDG_CONFIG_HOME HOME="$TEST_HOME" EVAR_HOME="$EVAR_HOME" \
    zsh "$EVAR_SCRIPT" "$@"
}

# bg_evar <id> <evar-args...>: runs evar in the background with the standard
# temporary environment; its exit status lands in $TEST_ROOT/bg.<id>.status.
bg_evar() {
  local id=$1
  shift
  (
    evar_isolated "$@" < /dev/null > "$TEST_ROOT/bg.$id.out" 2> "$TEST_ROOT/bg.$id.err"
    print -r -- $? > "$TEST_ROOT/bg.$id.status"
  ) &
}

# bg_status <id>: prints the recorded exit status ("missing" if none).
bg_status() {
  if [[ -f $TEST_ROOT/bg.$1.status ]]; then
    print -r -- "$(<"$TEST_ROOT/bg.$1.status")"
  else
    print -r -- missing
  fi
}

# bg_reset: forget the results of earlier background runs.
bg_reset() {
  /bin/rm -f -- "$TEST_ROOT"/bg.*(N) 2> /dev/null
  return 0
}

# ---- suite end -------------------------------------------------------------

finish_suite() { # label
  if (( T_FAIL > 0 )); then
    print -u2 -r -- "$1: $T_FAIL failed, $T_PASS passed, $T_SKIP skipped"
    exit 1
  fi
  print -r -- "$1 passed ($T_PASS checks, $T_SKIP skipped)"
}
