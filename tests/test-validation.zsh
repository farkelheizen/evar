#!/bin/zsh

EVAR_SCRIPT="${0:A:h:h}/evar"
source "${0:A:h}/lib.zsh"

# ---- harness self-checks ---------------------------------------------------

begin_test 'harness refuses to run without EVAR_HOME'
( EVAR_HOME=''; run_evar --version ) > /dev/null 2>&1
STATUS=$?
check_status 99 'run_evar without EVAR_HOME'

begin_test 'harness isolates HOME and EVAR_HOME'
run_evar --version
check_status 0
[[ $EVAR_HOME == $TEST_ROOT/* ]] && (( ++T_PASS )) || t_fail 'EVAR_HOME is outside the temporary root'

# ---- Phase 0: platform byte-checking vectors -------------------------------
#
# The probe results from plan section 1.3, pinned as permanent vectors. Each
# row is  name|printf-bytes|class  where class is the first failing check of:
#   nul   - contains a NUL byte           (tr/cmp recipe)
#   utf8  - rejected by iconv             (invalid or truncated UTF-8)
#   range - accepted by iconv but above U+10FFFF (grep recipe)
#   ok    - valid
# macOS iconv accepts NUL and code points above U+10FFFF, which is why the
# extra recipes exist; these rows fail if a future macOS changes that.

typeset -a UTF8_VECTORS=(
  'ascii|hello|ok'
  'empty||ok'
  'two-byte e-acute|\xc3\xa9|ok'
  'four-byte emoji|\xf0\x9f\x98\x80|ok'
  'highest scalar U+10FFFF|\xf4\x8f\xbf\xbf|ok'
  'continuation bytes that collide with zsh internals|\xc3\x83 \xc2\xa1 \xc2\x9b|ok'
  'lone 0xFF|\xff|utf8'
  'overlong slash|\xc0\xaf|utf8'
  'surrogate U+D800|\xed\xa0\x80|utf8'
  'stray continuation byte|\x80|utf8'
  'truncated three-byte sequence|\xe2\x82|utf8'
  'above Unicode F4 90 80 80|\xf4\x90\x80\x80|range'
  'above Unicode F5 80 80 80|\xf5\x80\x80\x80|range'
  'embedded NUL|a\0b|nul'
)

# The recipes evar relies on. NUL is detected in memory: zsh keeps NUL bytes in
# the result of $(<file), so every check sees one snapshot of the bytes. iconv
# and grep run on that same value.
probe_file_class() { # file
  local data
  data=$(<"$1")
  [[ $data != *$'\0'* ]] || { print nul; return }
  print -rn -- "$data" | /usr/bin/iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1 || { print utf8; return }
  if print -rn -- "$data" | LC_ALL=C /usr/bin/grep -a -E $'\xf4[\x90-\xbf]|[\xf5-\xff]' > /dev/null; then
    print range
    return
  fi
  print ok
}

begin_test 'platform premise: iconv accepts NUL and code points above U+10FFFF'
# These are the facts that force evar's extra checks (plan section 1.3). If a
# future macOS makes iconv stricter, this fails and the checks can be revisited.
printf 'a\0b' | /usr/bin/iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check_eq $? 0 'iconv accepts an embedded NUL'
printf '\xf4\x90\x80\x80' | /usr/bin/iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check_eq $? 0 'iconv accepts F4 90 80 80'

begin_test 'platform premise: zsh keeps NUL bytes through $(<file)'
printf 'a\0b\n' > "$TEST_ROOT/nul.bin"
data=$(<"$TEST_ROOT/nul.bin")
check_eq ${#data} 3 'length of a NUL-containing value'

for row in "${UTF8_VECTORS[@]}"; do
  parts=("${(@s:|:)row}")
  name=$parts[1] bytes=${parts[2]-} expected=$parts[3]
  begin_test "tool probe: $name"
  printf "$bytes" > "$TEST_ROOT/vector"
  check_eq "$(probe_file_class "$TEST_ROOT/vector")" "$expected" "classification of $name"
done

# ---- Phase 2: identifiers --------------------------------------------------

x=''
LONG64=${(l:64::a:)x}
LONG65=${(l:65::a:)x}
LONG128=${(l:128::A:)x}
LONG129=${(l:129::A:)x}

# check_pred <function> <valid|invalid> <input>: "valid" means the predicate
# succeeds (exit 0), "invalid" that it fails with exit 1; neither may print.
check_pred() {
  run_fn "$1" "$3"
  if [[ $2 == valid ]]; then
    check_status 0 "$1 ${(qq)3} should succeed"
  else
    check_status 1 "$1 ${(qq)3} should fail"
  fi
  check_out_empty "$1 stdout"
}

typeset -a ORG_VALID=(
  a A 0 9lives acme acme-corp acme_corp a.b v1.2.3 a--b a..b Acme.Tools
  "$LONG64"
  # legal near-misses for the device-name guard
  COM10 COM0 LPT0 console aux1 nullable com lpt con-x a.con prn1 conx
)
typeset -a ORG_INVALID=(
  '' . .. -a _a .a a/b 'a\b' 'a b' a:b 'a*b' 'a?b' 'a<b' 'a"b' 'a|b' a=b
  "$LONG65"
  $'a\nb' $'a\n' $'\na' 'é' 'aé' '日本'
  # D5(a): a trailing dot is stripped by Windows, so acme. would collide with acme
  acme. a.. v1.
  # D5(b): reserved device stems, case-insensitive, any extension
  con CON Con prn PRN aux AUX nul NUL COM1 com9 Com5 LPT1 lpt9 LpT5 nul.txt CON.txt
  nul.tar.gz lpt9.x com1.a.b
)

for x in "${ORG_VALID[@]}"; do
  begin_test "valid_org_like accepts ${(qq)x[1,24]}"
  check_pred valid_org_like valid "$x"
done
for x in "${ORG_INVALID[@]}"; do
  begin_test "valid_org_like rejects ${(qq)x[1,24]}"
  check_pred valid_org_like invalid "$x"
done

begin_test 'valid_version accepts _ and org-like names only'
for x in _ dev v1-dev 1 prod v1.2 "$LONG64"; do check_pred valid_version valid "$x"; done
for x in '' __ _a _. -x .x 'a/b' acme. con nul.txt COM1 "$LONG65"; do check_pred valid_version invalid "$x"; done

typeset -a VAR_VALID=(
  A a _ _A FOO_BAR1 a1 Z9_ "$LONG128"
  COM10 COM CONSOLE NULL AUX1 LPT0 CONS
)
typeset -a VAR_INVALID=(
  '' 1A 9 A-B A.B 'A B' A=B 'A/B' $'A\nB' 'é' 'Aé' "$LONG129"
  # D5(c): the device-name guard applies to variables too
  CON con NUL nul Prn PRN AUX aux COM1 com9 LPT1 lpt9
)

for x in "${VAR_VALID[@]}"; do
  begin_test "valid_variable accepts ${(qq)x[1,24]}"
  check_pred valid_variable valid "$x"
done
for x in "${VAR_INVALID[@]}"; do
  begin_test "valid_variable rejects ${(qq)x[1,24]}"
  check_pred valid_variable invalid "$x"
done

begin_test 'is_reserved_device_stem matches the stem before the first dot, case-insensitively'
for x in con CON Con.x nul.tar.gz COM1 com9.txt LPT1 lpt9.a.b PRN AUX; do check_pred is_reserved_device_stem valid "$x"; done
for x in COM10 COM0 LPT0 console aux1 nullable a.con x.nul '' com; do check_pred is_reserved_device_stem invalid "$x"; done

# ---- Phase 2: scope parsing ------------------------------------------------

typeset -g DUMP_SCOPE='parse_scope "$1"; print -r -- "$SCOPE_ORG|$SCOPE_MODULE|$SCOPE_VERSION"'
typeset -g DUMP_PREFIX='parse_scope_prefix "$1"; print -r -- "$SCOPE_DEPTH|$SCOPE_ORG|$SCOPE_MODULE|$SCOPE_VERSION"'

begin_test 'parse_scope: two or three segments, default version is _'
typeset -a SCOPE_CASES=(
  'acme/app|acme|app|_'
  'acme/app/_|acme|app|_'
  'acme/app/dev|acme|app|dev'
  'acme/app/v1-dev|acme|app|v1-dev'
  'Acme.Tools/my_app/v1.2.3|Acme.Tools|my_app|v1.2.3'
  'a/b/COM10|a|b|COM10'
)
for row in "${SCOPE_CASES[@]}"; do
  parts=("${(@s:|:)row}")
  run_snippet "$DUMP_SCOPE" "$parts[1]"
  check_status 0 "parse_scope ${(qq)parts[1]}"
  check_out "${parts[2]}|${parts[3]}|${parts[4]}" "parse_scope ${(qq)parts[1]} result"
done

begin_test 'parse_scope rejects malformed scopes with exit 1 and a diagnostic'
typeset -a BAD_SCOPES=(
  '' a / acme// a//b /a/b a/b/ a/b/c/ a/b/c/d a/b/c/d/e
  a/../b ../a/b a/b/.. a/./b a/b/. a/b/_x a/b/__ a/./.
  acme./app a/b/c. a/con a/b/con a/b/nul.txt con/a/b a/b/COM1
  'a b/c' 'a/b c' 'a/b/c d' 'a\b/c' a/b:c/d $'a/b\n/c' $'a/b/c\n' 'é/b' 'a/é' 'a/b/é'
  "$LONG65/b" "a/$LONG65" "a/b/$LONG65"
)
for x in "${BAD_SCOPES[@]}"; do
  begin_test "parse_scope rejects ${(qq)x[1,24]}"
  run_snippet "$DUMP_SCOPE" "$x"
  check_status 1 "parse_scope ${(qq)x[1,24]}"
  check_out_empty
  [[ $ERR == 'evar: '* ]] && (( ++T_PASS )) || t_fail "diagnostic lacks the evar: prefix: ${(q)ERR}"
done

begin_test 'parse_scope_prefix: one to three segments, no default version'
typeset -a PREFIX_CASES=(
  'acme|1|acme||'
  'acme/app|2|acme|app|'
  'acme/app/dev|3|acme|app|dev'
  'acme/app/_|3|acme|app|_'
)
for row in "${PREFIX_CASES[@]}"; do
  parts=("${(@s:|:)row}")
  run_snippet "$DUMP_PREFIX" "$parts[1]"
  check_status 0 "parse_scope_prefix ${(qq)parts[1]}"
  check_out "${parts[2]}|${parts[3]}|${parts[4]-}|${parts[5]-}" "parse_scope_prefix ${(qq)parts[1]} result"
done
for x in '' / acme/ /acme a//b a/b/c/d a/.. con a/con a/b/nul acme. a/b/c.; do
  begin_test "parse_scope_prefix rejects ${(qq)x}"
  run_snippet "$DUMP_PREFIX" "$x"
  check_status 1 "parse_scope_prefix ${(qq)x}"
  check_out_empty
done

begin_test 'identifier diagnostics name the bad segment and the rule'
run_snippet "$DUMP_SCOPE" 'acme/con/dev'
check_err_has "invalid module 'con'"
check_err_has 'reserved'
run_snippet "$DUMP_SCOPE" 'acme.'
check_status 1
run_snippet 'require_variable "$1"' '1BAD'
check_status 1
check_err_has "invalid variable name '1BAD'"

# ---- Phase 2: values -------------------------------------------------------

typeset -a VALUE_VALID=(
  '' plain 'with space' '=equals' '-leading' "quo'te\"s" '$(touch CANARY)'
  '`touch CANARY`' ';|&' '*?[a-z]' '${HOME}' '\n literal backslash n' '  padded  '
  $'tab\there' 'é' '😀' '日本語' $'\xf4\x8f\xbf\xbf' 'ƒ ¡' $'\xc3\x83 \xc2\xa1 \xc2\x9b'
)
typeset -a VALUE_BAD_LINE=($'a\nb' $'a\rb' $'a\r\nb' $'\n' $'\r' $'a\n' $'a\r' $'a\r\n' $'\na')
typeset -a VALUE_BAD_UTF8=($'\xff' $'a\xffb' $'\xc0\xaf' $'\xed\xa0\x80' $'\x80' $'\xe2\x82' $'\xf4\x90\x80\x80' $'\xf5\x80\x80\x80' $'ok\xc3')

for x in "${VALUE_VALID[@]}"; do
  begin_test "validate_value_string accepts ${(qq)x[1,24]}"
  run_fn validate_value_string "$x"
  check_status 0 "validate_value_string ${(qq)x[1,24]}"
  check_out_empty
done
for x in "${VALUE_BAD_LINE[@]}"; do
  begin_test "validate_value_string rejects line break ${(qq)x}"
  run_fn validate_value_string "$x"
  check_status 2 "validate_value_string ${(qq)x}"
  check_err_has 'single line'
done
for x in "${VALUE_BAD_UTF8[@]}"; do
  begin_test "validate_value_string rejects invalid UTF-8 ${(qq)x}"
  run_fn validate_value_string "$x"
  check_status 2 "validate_value_string ${(qq)x}"
  check_err_has 'UTF-8'
done

begin_test 'validate_value_string rejects a NUL carried in a variable (as from stdin)'
run_snippet "v=\$'a\\0b'; validate_value_string \"\$v\""
check_status 2
check_err_has 'NUL'

begin_test 'value diagnostics never echo the value'
run_fn validate_value_string $'CANARYVALUE\nsecond'
check_status 2
check_err_lacks 'CANARYVALUE'
run_fn validate_value_string $'CANARYVALUE\xff'
check_status 2
check_err_lacks 'CANARYVALUE'

# A very large invalid value must still be rejected (no SIGPIPE false negative).
begin_test 'validate_value_string catches an out-of-range scalar after a large prefix'
x=''
BIGBYTES=${(l:200000::a:)x}$'\xf4\x90\x80\x80'
print -rn -- "$BIGBYTES" > "$TEST_ROOT/big"
run_snippet 'validate_value_string "$(<"$1")"' "$TEST_ROOT/big"
check_status 2
check_err_has 'UTF-8'

# ---- Phase 2: stored-file values -------------------------------------------

for row in "${UTF8_VECTORS[@]}"; do
  parts=("${(@s:|:)row}")
  name=$parts[1] bytes=${parts[2]-} expected=$parts[3]
  begin_test "validate_value_file: $name"
  printf "$bytes" > "$TEST_ROOT/vector"
  run_fn validate_value_file "$TEST_ROOT/vector" 'acme/app/_/VAR'
  if [[ $expected == ok ]]; then
    check_status 0 "validate_value_file $name"
  else
    check_status 2 "validate_value_file $name"
    check_err_has 'acme/app/_/VAR'
  fi
done

# validate_value_file <file> <label> sets REPLY to the value with every
# trailing CR/LF removed (D10); interior CR or LF is a value failure (D3).
typeset -g DUMP_FILE='validate_value_file "$1" label; print -rn -- "$REPLY"'
typeset -a FILE_CASES=(
  'v1\n|v1'
  'v1|v1'
  'v1\r\n|v1'
  'v1\r\n\r\n|v1'
  'v1\n\n\n|v1'
  'v1\r\r\n|v1'
  'v1\r|v1'
  '\n|'
  '\r\n|'
  '|'
  '  padded \n|  padded '
  'a=b c\n|a=b c'
  'tab\there\n|tab\there'
)
for row in "${FILE_CASES[@]}"; do
  parts=("${(@s:|:)row}")
  begin_test "validate_value_file strips trailing CR/LF: ${(qq)parts[1]}"
  printf "$parts[1]" > "$TEST_ROOT/vector"
  run_snippet "$DUMP_FILE" "$TEST_ROOT/vector"
  check_status 0
  check_out_exact "$(printf "${parts[2]-}")"
done
for bytes in 'a\nb\n' 'a\rb\n' 'a\r\nb\r\n' '\nab\n' 'a\n\rb'; do
  begin_test "validate_value_file rejects interior line break: ${(qq)bytes}"
  printf "$bytes" > "$TEST_ROOT/vector"
  run_snippet "$DUMP_FILE" "$TEST_ROOT/vector"
  check_status 2
  check_err_has 'label'
  check_out_empty
done

begin_test 'validate_value_file diagnostics never echo file contents'
printf 'CANARYVALUE\nsecond\n' > "$TEST_ROOT/vector"
run_snippet "$DUMP_FILE" "$TEST_ROOT/vector"
check_status 2
check_err_lacks 'CANARYVALUE'
printf 'CANARYVALUE\xff\n' > "$TEST_ROOT/vector"
run_snippet "$DUMP_FILE" "$TEST_ROOT/vector"
check_status 2
check_err_lacks 'CANARYVALUE'

begin_test 'validate_value_file: a file that is gone is "missing" (1); other read failures are I/O errors (3)'
typeset -g STATUS_FILE='validate_value_file "$1" label; rc=$?; print -rn -- "$REPLY"; exit $rc'
run_snippet "$STATUS_FILE" "$TEST_ROOT/does-not-exist"
check_status 1
check_out_empty
/bin/mkdir -p -- "$TEST_ROOT/adir"
run_snippet "$STATUS_FILE" "$TEST_ROOT/adir"
check_status 3 'a directory'
if is_root; then
  skip_test 'running as root; unreadable-file case needs enforced permissions'
else
  print -r -- x > "$TEST_ROOT/noperm"
  /bin/chmod 000 "$TEST_ROOT/noperm"
  run_snippet "$STATUS_FILE" "$TEST_ROOT/noperm"
  check_status 3 'an unreadable file'
  /bin/chmod 600 "$TEST_ROOT/noperm"
fi

finish_suite 'Validation tests'
