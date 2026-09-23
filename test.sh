#!/usr/bin/env bash
# Checks gh-pat against the contract in SPEC.md. No dependencies and no network.
#
# Neither store is the real one. GH_CONFIG_DIR points every case at a hosts.yml fixture
# built here, and tests/stub-security stands in for the security binary on PATH, so no
# case can read or write a credential that belongs to whoever is running this.
#
#   ./test.sh            run everything
#   ./test.sh switch     run only cases whose name contains "switch"
#   ./test.sh -q         totals only, for anything reading the output rather than watching it
#
# Two things remain out of reach: a terminal, which every prompt and the picker need, and
# a live token, which validation and expiry need. Those are in the table in
# docs/verifying-a-change.md, to be run by hand — along with the checks that exist to confirm
# the stub still resembles the real security. Also absent is everything under "Open
# questions" in SPEC.md, where pinning an undecided behavior would promote an accident
# to a contract.
set -uo pipefail

cd "$(dirname "$0")"
readonly SCRIPT=./gh-pat

quiet=false
if [[ ${1-} == -q ]]; then quiet=true; shift; fi
filter=${1-}

pass=0 fail=0 skipped=0
failures=()

# ---------------- harness ----------------

# Sections exist for the reader: a run that prints nothing until the end looks stalled,
# and the totals alone do not say what was covered.
#
# On a terminal the whole list is printed up front and each line filled in as its section
# finishes, so the shape of the run is visible from the first moment. That needs the
# cursor moved backwards, which only makes sense when something is watching — piped
# output and -q both fall back to appending a line per section as it completes.
SECTION='' sec_pass=0 sec_fail=0 sec_index=0

if [[ -t 1 ]] && ! $quiet; then live=true; else live=false; fi

# The section names, in the order they run. Pulled from this file so the list cannot fall
# out of step with the calls below.
SECTIONS=()
while read -r s; do SECTIONS[${#SECTIONS[@]}]=$s; done < <(sed -n 's/^section //p' "$0")
readonly SECTION_COUNT=${#SECTIONS[@]}

# Every line starts as the name alone; the result is written over it later.
print_pending() {
  local s
  for s in "${SECTIONS[@]}"; do printf '  %-14s\n' "$s"; done
}

sec_result() {  # the text that replaces a pending line
  if (( sec_fail )); then
    printf '  %-14s %3d passed, %d failed' "$SECTION" "$sec_pass" "$sec_fail"
  else
    printf '  %-14s %3d passed' "$SECTION" "$sec_pass"
  fi
}

report_section() {
  [[ -n $SECTION ]] || return 0
  if (( sec_pass + sec_fail )); then
    if $live; then
      # Jump back to this section's line, rewrite it, and return to the bottom.
      local up=$(( SECTION_COUNT - sec_index + 1 ))
      printf '\033[%dA\033[2K%s\033[%dB\r' "$up" "$(sec_result)" "$up"
    elif ! $quiet; then
      sec_result; echo
    fi
  fi
  sec_pass=0 sec_fail=0
}

section() {
  report_section
  SECTION=$1
  sec_index=$(( sec_index + 1 ))
}

# check <name> <expected> <actual>
check() {
  local name=$1 expected=$2 actual=$3
  if [[ -n $filter && $name != *"$filter"* ]]; then
    skipped=$(( skipped + 1 ))
    return
  fi
  if [[ $expected == "$actual" ]]; then
    pass=$(( pass + 1 )); sec_pass=$(( sec_pass + 1 ))
  else
    fail=$(( fail + 1 )); sec_fail=$(( sec_fail + 1 ))
    failures[${#failures[@]}]="$name
    expected: [${expected}]
    actual:   [${actual}]"
  fi
}

# Runs the script against a fixture with stdin closed, so any path that reaches a
# prompt fails visibly here instead of hanging.
run()    { GH_CONFIG_DIR="$1" "$SCRIPT" "${@:2}" 2>&1 </dev/null; }
stdout() { GH_CONFIG_DIR="$1" "$SCRIPT" "${@:2}" 2>/dev/null </dev/null; }
rc()     { GH_CONFIG_DIR="$1" "$SCRIPT" "${@:2}" >/dev/null 2>&1 </dev/null; echo $?; }

# Pulls a function out of the script so it can be called directly. The alternative is
# sourcing gh-pat, which runs the dispatch and exits. awk rather than sed: a sed range
# built from a variable puts an unescaped brace in the pattern, which BSD sed reads as
# the start of a command block and GNU sed as a repetition operator.
borrow() {
  eval "$(awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) " { inside = 1 }
    inside { print }
    inside && /^\}/ { exit }
  ' "$SCRIPT")"
}

# aliases/active/has are one-liners, so the whole definition is on the matching line.
borrow_oneline() { eval "$(grep "^$1()" "$SCRIPT")"; }

# ---------------- fixtures ----------------

# Checked rather than assumed: an unset FIXTURES would make every path below start at
# the filesystem root, and the cleanup trap would be pointed there too.
FIXTURES=$(mktemp -d "${TMPDIR:-/tmp}/gh-pat-test.XXXXXX") || exit 1
[[ -d $FIXTURES ]] || { echo "could not create a temporary directory" >&2; exit 1; }
trap 'rm -rf "$FIXTURES"' EXIT

fixture() {  # fixture <name> <<'YAML'
  local dir="$FIXTURES/$1"
  mkdir -p "$dir"
  cat > "$dir/hosts.yml"
  printf '%s' "$dir"
}

# ---------------- the security stub ----------------

# gh-pat runs as a subprocess, so the stub has to be a file on PATH rather than a shell
# function. It lives in tests/ as an ordinary script — inline as a heredoc it would be a
# string, which no syntax check or linter would look at. Its state is KEYCHAIN, one
# `alias<TAB>value` per line; what it imitates and why is documented in the file itself.
readonly KEYCHAIN="$FIXTURES/keychain"
: > "$KEYCHAIN"
export KEYCHAIN

mkdir -p "$FIXTURES/bin"
ln -s "$PWD/tests/stub-security" "$FIXTURES/bin/security" || exit 1
PATH="$FIXTURES/bin:$PATH"

# A link that failed to take would send every lookup to the real binary, and the run would
# look like a pass on one machine and a mess on another. Better to stop here.
[[ $(command -v security) == "$FIXTURES/bin/security" ]] || {
  echo "the security stub is not first on PATH — refusing to run against the real one" >&2
  exit 1
}

# stored <alias> <value>...  — replaces the whole keychain state
stored() {
  : > "$KEYCHAIN"
  while (( $# )); do
    printf '%s\t%s\n' "$1" "$2" >> "$KEYCHAIN"
    shift 2
  done
}

b64() { printf 'go-keyring-base64:%s' "$(printf '%s' "$1" | base64)"; }

# Two aliases, one active — the ordinary case, and the one where switch has a single
# candidate. Nothing here has a Keychain entry, which is what puts every alias in the
# MISSING keychain state without writing anything.
TWO=$(fixture two <<'YAML'
github.com:
    git_protocol: https
    user: alpha
    users:
        alpha:
        bravo:
YAML
)

ONE=$(fixture one <<'YAML'
github.com:
    git_protocol: https
    user: solo
    users:
        solo:
YAML
)

THREE=$(fixture three <<'YAML'
github.com:
    git_protocol: https
    user: alpha
    users:
        alpha:
        bravo:
        charlie:
YAML
)

EMPTY=$(fixture empty <<'YAML'
github.com:
    git_protocol: https
    users:
YAML
)

ABSENT="$FIXTURES/absent"   # never created, so hosts.yml is missing

$live && print_pending

# ---------------- the stub itself ----------------
section stub

# Everything below trusts the stub to answer the way security does. A fault in it would
# quietly invalidate the lot — an early version returned a false exit status when asked
# only whether an entry existed, which made in_keychain report every alias as missing.
# So the stub is checked first, on its own terms.
S=$FIXTURES/bin/security

stored known "$(b64 ghp_x)"
check "stub: reports a stored entry"   0  "$($S find-generic-password -s gh:github.com -a known; echo $?)"
check "stub: returns the value"        "$(b64 ghp_x)" \
  "$($S find-generic-password -s gh:github.com -a known -w)"
check "stub: 44 for a missing entry"   44 "$($S find-generic-password -s gh:github.com -a nobody 2>/dev/null; echo $?)"
check "stub: 44 asking for its value"  44 "$($S find-generic-password -s gh:github.com -a nobody -w 2>/dev/null; echo $?)"
check "stub: says so on stderr" \
  "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." \
  "$($S find-generic-password -s gh:github.com -a nobody 2>&1 >/dev/null)"
check "stub: another service has nothing" \
  44 "$($S find-generic-password -s other.service -a known 2>/dev/null; echo $?)"

check "stub: service alone matches nothing" \
  44 "$($S find-generic-password -s gh:github.com 2>/dev/null; echo $?)"

# Writes land in the state file, which is what makes the roundtrip in login testable
$S add-generic-password -s gh:github.com -a fresh -w newvalue
check "stub: add is visible to find" "newvalue" \
  "$($S find-generic-password -s gh:github.com -a fresh -w)"

# Without -U the real security refuses an existing account and keeps the old value
check "stub: add without -U is refused" 45 \
  "$($S add-generic-password -s gh:github.com -a fresh -w other 2>/dev/null; echo $?)"
check "stub: and says why" \
  "security: SecKeychainItemCreateFromContent (<default>): The specified item already exists in the keychain." \
  "$($S add-generic-password -s gh:github.com -a fresh -w other 2>&1 >/dev/null)"
check "stub: the refused write changed nothing" "newvalue" \
  "$($S find-generic-password -s gh:github.com -a fresh -w)"

$S add-generic-password -s gh:github.com -a fresh -w replaced -U
check "stub: -U replaces the value" "replaced" \
  "$($S find-generic-password -s gh:github.com -a fresh -w)"
check "stub: and leaves one line" 1 "$(grep -c '^fresh	' "$KEYCHAIN")"

check "stub: delete reports what it did" "password has been deleted." \
  "$($S delete-generic-password -s gh:github.com -a fresh)"
check "stub: delete removes it" 44 \
  "$($S find-generic-password -s gh:github.com -a fresh 2>/dev/null; echo $?)"
check "stub: delete of a missing entry is 44" 44 \
  "$($S delete-generic-password -s gh:github.com -a fresh 2>/dev/null; echo $?)"

# The dump has to carry a record boundary per entry, or orphans() reads names across them
stored one "$(b64 ghp_x)" '<NULL>' "$(b64 ghp_y)"
check "stub: dump opens each record" 2 "$($S dump-keychain | grep -c '^keychain: ')"
check "stub: dump names an entry" '    "acct"<blob>="one"' \
  "$($S dump-keychain | sed -n 5p)"
check "stub: dump prints NULL unquoted" '    "acct"<blob>=<NULL>' \
  "$($S dump-keychain | sed -n 11p)"
check "stub: dump carries the service" 2 \
  "$($S dump-keychain | grep -c '"svce"<blob>="gh:github.com"')"

stored

# ---------------- invariant 5: current prints the alias and nothing else ----------------
section current

check "current prints only the alias"        "alpha" "$(stdout "$TWO" current)"
check "current is silent without hosts.yml"  ""      "$(stdout "$ABSENT" current)"
check "current exits 0"                      0       "$(rc "$TWO" current)"
check "current exits 0 without hosts.yml"    0       "$(rc "$ABSENT" current)"

# ---------------- invariant 6: --help, any position, any subcommand ----------------
section help

for cmd in login logout rotate switch list current; do
  for flag in -h --help; do
    check "help: $cmd $flag exits 0" 0 "$(rc "$TWO" "$cmd" "$flag")"
    check "help: $cmd $flag prints usage" "Manage multiple gh PATs under local aliases" \
      "$(run "$TWO" "$cmd" "$flag" | head -1)"
  done
done

# rotate parses options, so --help has to win from either side of one
check "help: rotate --all --help" 0 "$(rc "$TWO" rotate --all --help)"
check "help: rotate --help --all" 0 "$(rc "$TWO" rotate --help --all)"

# ---------------- conventions: exit codes ----------------
section conventions

check "no args exits 0"           0 "$(rc "$TWO")"
check "unknown command exits 1"   1 "$(rc "$TWO" bogus)"
check "list exits 0"              0 "$(rc "$TWO" list)"
check "list without hosts.yml"    1 "$(rc "$ABSENT" list)"
check "switch without hosts.yml"  1 "$(rc "$ABSENT" switch)"
check "logout without hosts.yml"  1 "$(rc "$ABSENT" logout)"
check "rotate without hosts.yml"  1 "$(rc "$ABSENT" rotate)"

# An unknown command reports the problem and then shows usage
check "unknown command message" "✗ unknown command: bogus" "$(run "$TWO" bogus | head -1)"

# ---------------- list ----------------
section list

# Nothing stored: every alias is registered but unusable
stored
check "list: MISSING keychain row" \
  "* alpha                      -              MISSING keychain" \
  "$(run "$TWO" list | head -1)"
check "list: active alias is marked" "*" "$(run "$TWO" list | head -c 1)"
check "list: inactive alias is not"  " " "$(run "$TWO" list | sed -n 2p | head -c 1)"
check "list: one row per alias"      3   "$(run "$THREE" list | wc -l | tr -d ' ')"
check "list: empty state"  "(no aliases)"  "$(run "$EMPTY" list)"

# Each token prefix reaches its own row, and a healthy row stops after the kind
stored alpha "$(b64 ghp_x)" bravo "$(b64 github_pat_x)"
check "list: classic"      "* alpha                      classic" "$(run "$TWO" list | head -1)"
check "list: fine-grained" "  bravo                      fine-grained" "$(run "$TWO" list | sed -n 2p)"

stored alpha "$(b64 gho_x)" bravo "$(b64 ghu_x)"
check "list: oauth" "* alpha                      oauth" "$(run "$TWO" list | head -1)"
check "list: app"   "  bravo                      app"   "$(run "$TWO" list | sed -n 2p)"

stored alpha "$(b64 something-else)" bravo "$(b64 '')"
check "list: unknown kind"   "* alpha                      unknown" "$(run "$TWO" list | head -1)"
check "list: undecodable"    "  bravo                      DECODE FAILED" "$(run "$TWO" list | sed -n 2p)"

# A value stored without the prefix still works but is flagged
stored alpha ghp_bare bravo "$(b64 ghp_x)"
check "list: nonstandard format" \
  "* alpha                      classic        nonstandard format" "$(run "$TWO" list | head -1)"
check "list: standard format is silent" \
  "  bravo                      classic" "$(run "$TWO" list | sed -n 2p)"

# An entry no alias refers to, listed after the registered ones
stored alpha "$(b64 ghp_x)" bravo "$(b64 ghp_y)" stray "$(b64 gho_z)"
check "list: keychain only row" \
  "  stray                      oauth          keychain only" "$(run "$TWO" list | sed -n 3p)"
check "list: keychain only comes last" 3 "$(run "$TWO" list | wc -l | tr -d ' ')"

# gh's own unnamed entry is not an alias and must not be listed
stored alpha "$(b64 ghp_x)" bravo "$(b64 ghp_y)" '<NULL>' "$(b64 ghp_active)"
check "list: unnamed entry is hidden" 2 "$(run "$TWO" list | wc -l | tr -d ' ')"

# "(no aliases)" reports the hosts.yml side only; stray entries still follow it
stored stray "$(b64 ghp_x)"
check "list: empty state still lists strays" \
  "  stray                      classic        keychain only" "$(run "$EMPTY" list | sed -n 2p)"

stored   # leave the keychain empty for the sections that follow

# ---------------- switch ----------------
section switch

stored
check "switch: 0 candidates names the active alias" \
  "* solo                       [MISSING keychain]" "$(run "$ONE" switch | head -1)"
check "switch: 0 candidates says so" \
  "No other alias to switch to." "$(run "$ONE" switch | sed -n 2p)"
check "switch: 0 candidates exits 0" 0 "$(rc "$ONE" switch)"

# The context line carries the active alias's kind, so a stored value shows there
stored solo "$(b64 ghp_x)"
check "switch: 0 candidates shows the kind" \
  "* solo                       [classic]" "$(run "$ONE" switch | head -1)"

# One candidate skips the menu. Without an entry it stops at the lookup; with one it gets
# as far as `gh auth switch`, which is outside the stub's reach.
stored
check "switch: 1 candidate skips the menu" \
  "✗ No keychain entry for 'bravo'. Run: gh pat login" "$(run "$TWO" switch | head -1)"
check "switch: 1 candidate exits 1"  1 "$(rc "$TWO" switch)"
check "switch: 2 candidates prompt"  "Cancelled." "$(run "$THREE" switch | head -1)"
check "switch: cancelling exits 0"   0 "$(rc "$THREE" switch)"

# ---------------- logout ----------------
section logout

check "logout: cancelling exits 0"  0 "$(rc "$TWO" logout)"

# Nothing registered and nothing stored: the picker has nothing to offer at all. This is
# only decidable because the stub owns the keychain — logout counts entries no alias refers
# to, so against a real one the menu would not be empty.
stored
check "logout: no aliases exits 1"  1 "$(rc "$EMPTY" logout)"
check "logout: no aliases message"  "✗ No aliases registered." "$(run "$EMPTY" logout | head -1)"

# A keychain only entry is enough to fill it, even with hosts.yml empty
stored stray "$(b64 ghp_x)"
check "logout: keychain only alone is offered" "Cancelled." "$(run "$EMPTY" logout | head -1)"
check "logout: and that is not an error"       0            "$(rc "$EMPTY" logout)"

stored

# ---------------- rotate: option parsing ----------------
section rotate

# Options are validated before the terminal check, so a typo is reported as a typo
# even here, where there is no terminal.
check "rotate: --days needs a number"  "✗ --days needs a whole number of days." \
  "$(run "$TWO" rotate --days abc | head -1)"
check "rotate: --days needs a value"   "✗ --days needs a whole number of days." \
  "$(run "$TWO" rotate --days | head -1)"
check "rotate: --days rejects negatives" "✗ --days needs a whole number of days." \
  "$(run "$TWO" rotate --days -5 | head -1)"
check "rotate: unknown option"         "✗ unknown option: --bogus" \
  "$(run "$TWO" rotate --bogus | head -1)"
check "rotate: --days abc exits 1"     1 "$(rc "$TWO" rotate --days abc)"
check "rotate: --bogus exits 1"        1 "$(rc "$TWO" rotate --bogus)"

# Valid options get past parsing and stop at the terminal check
check "rotate: needs a terminal"  "✗ rotate needs a terminal to paste tokens into." \
  "$(run "$TWO" rotate --days 7 | head -1)"
check "rotate: --all is valid"    "✗ rotate needs a terminal to paste tokens into." \
  "$(run "$TWO" rotate --all | head -1)"
check "rotate: --days 0 is valid" "✗ rotate needs a terminal to paste tokens into." \
  "$(run "$TWO" rotate --days 0 | head -1)"

# ---------------- borrowed functions ----------------
section helpers

borrow looks_like_token
kind() { if looks_like_token "$1"; then echo accept; else echo reject; fi; }

check "token: classic"        accept "$(kind ghp_abc123)"
check "token: oauth"          accept "$(kind gho_abc123)"
check "token: app user"       accept "$(kind ghu_abc123)"
check "token: app server"     accept "$(kind ghs_abc123)"
check "token: fine-grained"   accept "$(kind github_pat_11ABC_xyz)"
check "token: truncated"      reject "$(kind hp_abc123)"
check "token: no underscore"  reject "$(kind ghp)"
check "token: an alias"       reject "$(kind work-classic)"
check "token: a URL"          reject "$(kind https://github.com/settings/tokens)"
check "token: leading space"  reject "$(kind ' ghp_abc123')"
check "token: empty"          reject "$(kind '')"

# hosts.yml parsing, against the fixtures above
hosts="$TWO/hosts.yml"
borrow_oneline aliases
borrow_oneline active
borrow_oneline has

check "aliases: lists both"    "alpha bravo" "$(aliases | tr '\n' ' ' | sed 's/ $//')"
check "active: reads user:"    "alpha"       "$(active)"
check "has: known alias"       0             "$(has alpha; echo $?)"
check "has: unknown alias"     1             "$(has nobody; echo $?)"
check "has: partial match"     1             "$(has alph; echo $?)"

hosts="$EMPTY/hosts.yml"
check "aliases: empty map"     ""  "$(aliases)"
check "active: no user key"    ""  "$(active)"

hosts="$ABSENT/hosts.yml"
check "aliases: missing file"  ""  "$(aliases)"
check "active: missing file"   ""  "$(active)"

# ---------------- orphans: the dump-keychain scan ----------------
section orphans

# The PATH stub speaks for a healthy keychain, which is what the sections above need. This
# one is about the parser's edges — a foreign service, a record with no account line — and
# those cannot be expressed as stub state. So orphans() is borrowed and `security` shadowed
# by a shell function, which wins over the file on PATH inside this shell.
#
# The dump below repeats keychain:/class:/attributes: for every record, because that is
# what dump-keychain does — a fixture that prints the header once instead makes the parser
# look broken, since the reset it relies on would never fire between entries.
borrow orphans
HOST=github.com
security() { [[ $1 == dump-keychain ]] && printf '%s\n' "$DUMP"; }

dump() {  # dump <acct>... — NULL for gh's unnamed entry, other for a non-gh service
  local a
  for a in "$@"; do
    printf 'keychain: "/tmp/login.keychain-db"\nversion: 512\nclass: "genp"\nattributes:\n'
    case $a in
      NULL)  printf '    "acct"<blob>=<NULL>\n    "svce"<blob>="gh:github.com"\n' ;;
      other) printf '    "acct"<blob>="someone"\n    "svce"<blob>="other.service"\n' ;;
      *)     printf '    "acct"<blob>="%s"\n    "svce"<blob>="gh:github.com"\n' "$a" ;;
    esac
  done
}

# EMPTY has no aliases, so has() rejects every name and nothing is filtered out
hosts="$EMPTY/hosts.yml"
found() { DUMP=$(dump "$@"); orphans | tr '\n' ' ' | sed 's/ $//'; }

check "orphans: plain entries"      "one two" "$(found one two)"
check "orphans: NULL last"          "one"     "$(found one NULL)"
check "orphans: NULL first"         "one"     "$(found NULL one)"
check "orphans: NULL in the middle" "one two" "$(found one NULL two)"
check "orphans: NULL after another service" "one" "$(found one other NULL)"
check "orphans: other services ignored"     ""    "$(found other)"

# An entry with no acct line at all, which the record boundary handles the same way
DUMP='keychain: "/tmp/login.keychain-db"
version: 512
class: "genp"
attributes:
    "acct"<blob>="one"
    "svce"<blob>="gh:github.com"
keychain: "/tmp/login.keychain-db"
version: 512
class: "genp"
attributes:
    "svce"<blob>="gh:github.com"'
check "orphans: entry with no acct line" "one" "$(orphans | tr '\n' ' ' | sed 's/ $//')"

# A name in hosts.yml is registered, not an orphan
hosts="$TWO/hosts.yml"
check "orphans: registered names excluded" "stray" "$(found alpha stray)"

# ---------------- usage text ----------------
section usage

# The header block is the usage text, printed by a sed range. Forgetting to widen the
# range when a line is added silently truncates the output.
check "usage: reaches the last line" \
  "  gh pat current  print the active alias (for shell prompts)" \
  "$(run "$TWO" --help | sed -n '/gh pat current/p')"
check "usage: blank line after the summary" "" "$(run "$TWO" --help | sed -n 2p)"

# ---------------- report ----------------

report_section          # the last section has no `section` call after it to flush it

if (( fail )); then
  echo
  printf '%s\n\n' "${failures[@]}"
elif ! $quiet; then
  echo
fi
printf '%d passed' "$pass"
(( fail )) && printf ', %d failed' "$fail"
(( skipped )) && printf ', %d skipped' "$skipped"
echo
(( fail == 0 ))
