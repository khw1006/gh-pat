# SPEC.md

What `gh-pat` is supposed to do. README shows how to use it and `docs/` explains how it is built;
this file is the contract the tests check against.

Where the current implementation departs from what is written here, that is a bug in the
implementation unless the line says otherwise.

Two kinds of statement live here, and it matters which is which. **Invariants** are what the tool is
for; changing one means building something else. Everything after them is a **decision** — reasoned,
and reversible if the reasoning stops holding. Each decision carries its reasoning, because that is
what someone needs in order to argue with it.

## Invariants

These hold across every command, so where anything below disagrees with one, the invariant wins.

1. **A token is never printed.** Not on success, not in an error, not while debugging. `read -rs`
   keeps a paste off the screen and nothing may undo that.
2. **A token is never stored outside the Keychain.** No plaintext fallback, no temporary file, no
   environment variable.
3. **Nothing is written until the token has been checked.** The paste is invisible, so an unchecked
   value would surface much later as an alias that cannot authenticate.
4. **A failed check leaves the previous value intact.** Replacing a working token with a broken one
   is worse than not replacing it.
5. **`current` prints the alias on stdout and nothing else.** Shell prompts consume it verbatim.
6. **`--help` and `-h` print the usage block and exit `0`**, from any position, after any
   subcommand. `gh` passes the flag through rather than intercepting it, so a command that ignores
   it and runs anyway is a defect — worst of all an interactive one, which would answer a request
   for help with a prompt.

## Model

Terms the rest of this document is written in. An alias has a **state** — which stores know about it
— and, where an entry exists, a **kind**: two separate things about the same alias.

The split across two stores is `gh`'s doing, not a choice made here. The names below are ours, and
they appear verbatim in output, so renaming one changes the interface.

### State

Two stores hold the state, and they can disagree. Everything below turns on which of them knows about
a given alias.

```
hosts.yml    users: map    — which aliases exist, and which one is active
Keychain     gh:github.com — one entry per alias, holding the token
```

`gh` keeps one further `gh:github.com` entry with no account name, holding a copy of the active
token. It belongs to `gh` rather than to any alias, so it is not a state in the table below and never
appears in output.

| `hosts.yml` | Keychain | Name | Meaning |
| --- | --- | --- | --- |
| yes | yes | *registered* | The normal case. `gh` can authenticate as this alias. |
| yes | no | `MISSING keychain` | `gh` lists the alias and fails to authenticate with it. |
| no | yes | `keychain only` | A token nothing refers to. `gh auth logout` leaves one behind every time. |
| no | no | — | Not an alias. |

The Keychain namespace is shared with `gh` itself: a browser login stores its token under the account
name the API reports, in an entry indistinguishable from one this tool wrote. An alias equal to a
real login name therefore collides with `gh`, and either side can overwrite the other.

### Kind

Read from the stored value's prefix, after stripping `go-keyring-base64:` and decoding.

| Prefix | Reported as |
| --- | --- |
| `ghp_` | `classic` |
| `gho_` | `oauth` |
| `ghu_`, `ghs_` | `app` |
| `github_pat_` | `fine-grained` |
| decodes to empty | `DECODE FAILED` |
| anything else | `unknown` |

With no entry there is no prefix to read, which is why `list` shows `-` in that column and names the
state in the next one instead.

`oauth` and `app` values did not come from this tool — `login` only accepts a pasted token, and only
`gh` produces those two.

### What `security` is assumed to do

Every statement above about the Keychain rests on `/usr/bin/security` behaving as follows. None of it
is documented by Apple; it was established by running the commands. If any of it stops holding, this
document is wrong before the script is:

| Call | Assumed behavior |
| --- | --- |
| `find-generic-password -s S -a A` | exit `0` if that pair exists, `44` if not |
| `find-generic-password -s S -a A -w` | the stored value on stdout, same exit codes |
| `find-generic-password -s S` | exit `44` — an account is not optional |
| `add-generic-password -s S -a A -w V` | creates it; exit `45` and no change if it already exists |
| `add-generic-password ... -U` | creates or replaces, exit `0` either way |
| `delete-generic-password -s S -a A` | removes it and echoes the record; `44` if absent |
| `dump-keychain` | every item on the machine, no way to filter by service |

`dump-keychain` output repeats `keychain:`, `class:` and `attributes:` before each record, with
attributes in alphabetical order — so `acct` precedes `svce` within a record, and an entry with no
account prints `"acct"<blob>=<NULL>`, unquoted.

`tests/stub-security` implements exactly this table, which is how the tests reach states a real
Keychain would not hold. It also means the tests cannot notice when the table stops being true —
`docs/verifying-a-change.md` lists the manual checks that can.

## Conventions

**Exit codes.** `0` when the command did what was asked, including when the user cancels: declining a
prompt is an answer, not a failure. `1` when the command could not proceed — bad arguments, a missing
`hosts.yml` where one is required, a Keychain entry that should exist and does not.

**Streams.** Results go to stdout; errors, warnings and prompts go to stderr.

**Color.** Suppressed when stdout is not a terminal or `NO_COLOR` is set. No output depends on color
to be understood.

## Commands

### `current`

Exits `0` in every case, including no `hosts.yml` and no active alias — it runs on every shell
prompt, so it stays quiet rather than reporting problems.

### `list`

One row per alias in `hosts.yml`, then one per `keychain only` entry. `*` marks the active alias.

```
* work                       fine-grained
  work-classic               classic
  odd-one                    classic        nonstandard format
  gone                       -              MISSING keychain
  stray                      classic        keychain only
```

A healthy row ends after the token kind. Anything in the third column is a problem worth reporting:

- `MISSING keychain` — registered but no entry, which is why the kind column holds a `-`
- `keychain only` — an entry no alias refers to
- `nonstandard format` — stored without the `go-keyring-base64:` prefix. It still works through a
  fallback in `gh`'s keyring library, but neither this tool nor `gh` writes that form, so something
  else did

With no aliases registered, prints `(no aliases)` — an empty list is a fact worth stating, not
silence. Any `keychain only` entries are still listed below it.

Exit `1` if `hosts.yml` is absent — unlike `current`, this command's whole purpose is to report.

### `switch`

Activates another alias. The active one is never a candidate — it is shown as context above the
picker, marked with `*` as in `list`.

| Candidates | Behavior |
| --- | --- |
| 0 | Prints the active alias and `No other alias to switch to.` |
| 1 | Switches to it directly — a menu of one is a confirmation, and switching costs nothing to undo |
| 2 or more | Shows the picker |

Exit `1` if the chosen alias has no Keychain entry. Cancelling the picker exits `0`.

### `login`

Registers a token under an alias. Prompts for the alias, then the token.

The alias must match `^[A-Za-z0-9][A-Za-z0-9_-]*$`.

The check required by invariant 3 is two steps:

1. the prefix must be one of the known kinds
2. `GET /user` must return `200`

A failure re-prompts rather than exiting — the alias is already chosen, and a mistyped paste is worth
another try, not a restart. Empty input cancels.

Behavior by state:

| State | Behavior |
| --- | --- |
| *registered* | Asks before overwriting |
| `keychain only` | Reuses the name without asking — nothing in use is being replaced |
| `MISSING keychain` | Creates the entry; the `hosts.yml` line already exists and is left alone |
| not an alias | Creates both |

If the alias equals the token's own account name, warn and ask before writing: `gh auth login` writes
to that same entry, so the two would share one slot. It asks rather than refuses, because one person
with one account may reasonably want that name.

The Keychain is written first and `hosts.yml` only after the stored value reads back intact, so a
failure at either step leaves no alias registered — better nothing than a name `gh` lists and cannot
authenticate with.

On success, activates the alias and reports the token kind and the account it belongs to.

### `logout`

Removes an alias. The picker lists registered aliases first, then `keychain only` entries.

| State | Removes |
| --- | --- |
| *registered* | Keychain entry and the `hosts.yml` line |
| `keychain only` | Keychain entry only — there is no line, and it cannot be active |

Removing the active alias activates another one first, so `hosts.yml` never points at an alias that
is not there.

An `oauth` or `app` entry that is registered gets a warning before the confirmation: it came from
`gh auth login`, and removing it ends that session. `keychain only` entries skip the warning —
`gh` already ended that session, which is what left the entry behind.

Exit `1` if there are no aliases at all. Cancelling exits `0`.

### `rotate`

Replaces tokens at or near expiry. Reads each alias's expiry, offers the ones that qualify, and
stores what is pasted. `hosts.yml` is untouched: rotating a secret does not change which aliases
exist.

Options: `--days N` sets the threshold (default 15), `--all` walks every alias regardless. `--all`
overrides `--days` rather than combining, and says so. Invalid options exit `1`.

The first line states the filter in effect, so the skip lines below it read as verdicts against a
visible rule.

Expiry comes from the `github-authentication-token-expiration` response header. Four outcomes have to
stay distinct, and an empty header alone cannot tell them apart:

| Condition | Reported as | Offered? |
| --- | --- | --- |
| Header present and parseable | `expires in Nd` / `EXPIRED` | If within the threshold |
| `200` with no header | `no expiry` | Only with `--all` |
| `401`, or `403` that is not rate limiting | `REJECTED` | Always — it is already useless |
| Anything else non-`200`, or an unparseable date | `expiry unknown` | Only with `--all` |

`403` counts as rejected only when `x-ratelimit-remaining` is not `0`: an exhausted quota means the
request failed, not the token. Unknown entries are counted and reported again at the end, because an
alias that could not be checked may be the one that needed rotating.

No automated check covers this table. The classification is written inline in the alias loop rather
than in a function, so `test.sh` cannot call it, and reaching it any other way needs a Keychain entry
and a live response — check it by hand after touching it.

Replacements go through the same two-step check as `login`. A failure re-prompts for the same alias
rather than moving on; Enter skips to the next.

Requires a terminal, checked before any API call so the failure is a sentence rather than a raw
device error partway through the loop. Options are validated before that check, so a typo is reported
as a typo even with no tty to report it to.

## Deliberately undefined

- **Multiple hosts.** Only `github.com`. The `hosts.yml` handling assumes one host and a fixed
  four-space layout.
- **Non-macOS.** The script exits immediately elsewhere.
- **Anything else writing to the same stores while a command runs.** Another `gh-pat`, a
  `gh auth login` in a second terminal, Keychain Access — none of it is coordinated with. `login`
  decides whether an entry exists before asking for the token, so one appearing in between makes the
  write fail; nothing is registered in that case, but the message comes from `security` rather than
  from here.
- **Extra positional arguments.** Commands that take no options ignore them rather than rejecting
  them, which is why `gh pat list foo --help` does not print help.
- **Timezones other than UTC** in the expiry header. The parser strips the zone and assumes UTC,
  which is what GitHub sends today; a numeric offset would parse without error and be wrong by that
  offset.

## Open questions

Undecided rather than settled. The script does something in each case; whether it is the right thing
has not been agreed, so tests should leave these alone until it is — pinning them now would turn an
accident into a contract.

- **Ordering in `list`.** Registered aliases come out in `hosts.yml` order and `keychain only`
  entries alphabetically. Neither is a decision, just what the implementation happens to produce.
- **Cancelling without a terminal.** `switch` and `logout` treat "no tty" the same as a cancelled
  picker and exit `0`, so a script that calls them does nothing and reports success. Whether that
  should be an error is open.
- **A failed `gh auth switch`.** `login` reports success after storing the token even if activating
  the alias fails, because the call's output is discarded. The token really was stored, so `1` would
  also mislead.
- **Removing the last alias.** `logout` deletes the `user:` line when there is nothing left to
  activate, leaving `hosts.yml` with an empty `users:` map. Whether `gh` is content with that has
  not been checked.
- **`rotate`'s framing.** The summary says "at or near expiry", but a `REJECTED` token is offered
  whatever its expiry — the table below is authoritative until the wording is settled.
- **A missing `hosts.yml` in `login`.** The skeleton is written from scratch, which is right, but the
  spec's state table does not cover the case of no file at all.
