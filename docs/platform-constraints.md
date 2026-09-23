# Platform constraints

These are not style preferences. Violating any of them produces a script that fails on a real
machine.

**bash 3.2.** macOS ships bash 3.2 and the shebang is `/usr/bin/env bash`, so assume 3.2 unless the
code explicitly branches on `BASH_VERSINFO`. This rules out associative arrays, `mapfile`/`readarray`,
`${var^^}`, and `read -t` with fractional seconds. The `ESC_T` constant near the top exists solely
because `read -rsn2 -t 0.05` is a syntax error on 3.2 — it fails instantly, which made arrow keys
read as a bare ESC and cancel the menu.

**BSD tools.** `sed -i ''` requires the empty-string argument on macOS and breaks on GNU sed. `base64`
has different flags across platforms. The script guards with a `uname` check at the top; keep it.

**`set -euo pipefail` interacts badly with arithmetic.** Write `sel=$(( ... ))`, never
`(( sel = ... ))`. The latter returns exit status 1 when the result is 0, which kills the script the
moment a menu index wraps to the first item.

**Array append must be index-based.** `arr[${#arr[@]}]=value`, not `arr+=(value)`, for 3.2 safety.

## One file

Do not split the script into multiple files. `gh` extensions resolve to a single executable matching
the repository name, and a one-file tool is trivial to audit — which matters for something that
touches credentials.

## No dependencies

No `yq`, `jq`, or `python`. The `sed`/`grep`/`awk` handling of `hosts.yml` is deliberate — the file
has a fixed four-space layout and one host. If multi-host support is ever needed, that is the point
at which a real YAML parser becomes justified, and it is a separate decision.

Do not assume the `hosts.yml` indentation is flexible. It is four spaces per level and the patterns
hardcode that; if `gh` changes it, the patterns change with it rather than becoming loose.

## Handling tokens

- Never print, log, or echo a token. `login` reads it with `read -rs` and unsets it immediately.
- Store tokens nowhere but the Keychain. No plaintext fallback, no `--insecure-storage` equivalent.
