# Verifying a change

## What `test.sh` covers

**`test.sh` never calls the real `security`.** A test that reads the live Keychain depends on what
happens to be registered on that machine, so a failure no longer says whether the code or the
environment is at fault. `tests/stub-security` stands in for it on `PATH`, which the `gh-pat`
subprocess inherits, answering from a state file the test wrote; writes land there too, so nothing a
run does can touch a real credential.

It is a file rather than a heredoc inside `test.sh` because a stub embedded as a string is invisible
to `bash -n` and to any linter. The first version carried an exit-status bug that neither would have
caught.

`./test.sh` covers exit codes, `--help` everywhere, output shape per state, option parsing, the pure
helpers, and anything that turns on a stored value. It reports per section as it goes, so a run shows
what was covered rather than a bare total. `./test.sh <word>` narrows it to matching cases, and
`./test.sh -q` prints only the totals — failures are always shown either way.

`GH_CONFIG_DIR` redirects `hosts.yml`, so the real one is safe as well.

## What it cannot cover

- **A terminal.** `menu_select` returns immediately without one, and `ask`/`ask_secret` fail on
  `/dev/tty`, so every prompt, the picker and the cursor handling are out of reach.
- **A live token.** Validation and expiry come from a real API response.
- **Whether `security` behaves as assumed.** The stub implements the table in
  [`../SPEC.md`](../SPEC.md), which was established by running the commands rather than reading a
  specification. If macOS changes any of it, every test still passes and the tool still breaks. That
  is a question for a person, not a test.

## Manual checks

These need a terminal, a live token, or the real `security`. Run the ones a change actually touches
rather than the whole list. Where a row says *real keychain*, the point is that the stub is not being
exercised: whether `security` itself still behaves as assumed can only be answered by calling it.

An agent working in a sandbox has none of these, so it should ask you to run the relevant rows.

| Check | Needs | How |
| --- | --- | --- |
| A pasted token survives intact | real keychain, tty, token | `login`, then `list` — the kind must change from `MISSING keychain` to the real one |
| A malformed paste is refused and re-prompts | tty | `login`, paste `notatoken` — the prompt must come back rather than the command ending |
| A well-formed but dead token is refused | tty, network | `login` with `ghp_` plus nonsense |
| Empty input cancels without storing | tty | `login`, press Enter at the token prompt |
| An alias equal to the account name warns first | tty, token | `login` with your own GitHub login as the alias |
| Overwriting asks; a `keychain only` name does not | real keychain, tty | `login` against each in turn |
| Arrow keys move, `q` and ESC cancel | tty | `switch` with three or more aliases |
| The menu collapses to one answered line | tty | `switch`, then check the scrollback holds that line and no menu rows |
| The cursor comes back after a normal exit and after Ctrl-C | tty | `switch`, then again killing it mid-menu |
| A single candidate switches, and `gh` follows | real keychain, tty | `switch` with exactly two aliases |
| Removing an entry clears it from both stores | real keychain, tty | `logout`, then `list` |
| A `keychain only` entry can be removed | real keychain, tty | `gh auth logout`, then `gh pat logout` |
| Removing an `oauth` entry warns first | real keychain, tty | `gh auth login`, then `gh pat logout` on it |
| Expiry is read and classified | real keychain, network | `rotate --all` against tokens with and without expiry |
| A rejected token is offered whatever its expiry | real keychain, network | `rotate` with a revoked token registered |
| A failed replacement leaves the old value | real keychain, tty, network | `rotate`, paste nonsense, then `list` |
| `git push` follows the active alias | real keychain, network, `gh auth setup-git` already run | `switch`, then push from any repo |

`menu_select` hides the cursor and restores it through a trap, so a change there can leave the
terminal without one, or leak a stray `[B` into the shell prompt. Both survive the command that
caused them, which is why the two cursor rows above are listed separately.

To confirm a stored value by hand:

```bash
security find-generic-password -s gh:github.com -a <alias> -w \
  | sed 's/^go-keyring-base64://' | base64 -d
gh auth switch -u <alias> && gh api user --jq .login
```
