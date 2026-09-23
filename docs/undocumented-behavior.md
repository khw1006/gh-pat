# Undocumented behavior this depends on

All of the following was determined experimentally, by running the commands and reading what came
back. None of it is specified anywhere. What belongs to `gh` can change in one of its releases; what
belongs to `security` can change with macOS, and neither will announce it.

## `hosts.yml` and the Keychain

**`hosts.yml` is the enumeration source.** `gh` lists the `users:` map and looks each name up in the
Keychain. It does not validate that a name is a real account, which is the entire basis of this tool.
An alias present in `hosts.yml` but missing from the Keychain shows up but fails to authenticate; the
reverse is invisible to `gh`. `gh-pat list` reports both directions.

**Keychain service name is `gh:github.com`**, account is the alias. There is no way to configure it,
and `GH_CONFIG_DIR` does not participate — separate config directories share one Keychain namespace.

**One `gh:github.com` entry has no account name.** `gh` keeps a copy of the active token there, so
the namespace holds one more entry than there are aliases, and `dump-keychain` prints its account as
`"acct"<blob>=<NULL>` — no quoted value, so the `"acct"<blob>="` pattern skips the line entirely.

That entry should not exist by the Security framework's own rules: `kSecAttrAccount` and
`kSecAttrService` together form the primary key of a generic password, so account is required. What
is stored is presumably an empty string that `dump-keychain` renders as `<NULL>`. Either way the
scan has to tolerate it, which is what the `acct!=""` test does. Nothing about the dump format is
documented — there is no schema for it in the `security` man page — so treat every detail of the
parsing as observed rather than promised.

The `/^keychain: /` reset in `orphans()` is what makes that harmless, and it is load-bearing.
`dump-keychain` repeats `keychain:`, `class:` and `attributes:` before *every* record, not once per
file, so the reset fires between entries and an unnamed one cannot inherit the name above it. On a
machine with 187 items all three lines appeared 187 times, and `class:` followed within three lines
of `keychain:` in every one — enough to treat it as the record boundary, though the format is
observed rather than specified.

A fixture that prints the header once will make the parser look broken. Shape dumps like the real
output.

**Parsing `dump-keychain` is not a workaround — it is the only way.** `find-generic-password` takes
`-s`, but a service on its own matches nothing at all, and there is no "find all" flag —
`find-certificate` has `-a` for exactly that and the password commands never got one. go-keyring,
which `gh` itself uses, reaches the same conclusion: its `ListUsers` shells out to `dump-keychain`
and parses the same two attributes, and handles the unnamed entry by writing an empty account when
the `="` pattern is absent.

**That namespace is shared with `gh` itself.** A browser login stores its `gho_` token under the
account name the API reports, in an entry this tool cannot distinguish from its own. So an alias
equal to a real login name is not a private label — it is the same entry `gh auth login` writes to,
and either side overwrites the other without noticing. `login` warns when the alias matches the
token's own account and asks before writing — after the write there is nothing left to decide. It
does not refuse outright, because one person with one account may reasonably want that name. The
same sharing means an `oauth` or `app` entry in `hosts.yml` reached the keychain through `gh`, so
`logout` warns before removing one and points at `gh auth logout` instead.

**Value format is `go-keyring-base64:` + base64.** Raw values also work today via a fallback path in
go-keyring, but that fallback is likely legacy compatibility and may be removed. Keep writing the
prefixed form so entries are byte-identical to what `gh auth login` produces.

`list` says nothing about the format on a normal row — both this tool and `gh` always write the
prefix, so a column repeating that on every line carries no information. A missing prefix means some
third thing wrote to the entry, which is worth flagging, so only that case prints
`nonstandard format`, not `raw`. It is not called a legacy format either — the prefixed form came
first, and the bare one was never what `gh` produced.

## `security`

**`gh` reads the Keychain by shelling out to `/usr/bin/security`** (via zalando/go-keyring). This is
why new entries are created with `-T /usr/bin/security` and why no partition-list call is needed —
entries created by `security` already carry the right partition. It is also why the ACL trusts
`security` rather than the `gh` binary.

**`-T` appends, it does not replace.** Each `add-generic-password -T` call adds another entry to the
trusted-application list without deduplicating, and on an existing item it counts as an ACL change,
which makes macOS prompt for the keychain password. `-T` therefore belongs only on first creation;
rotation passes `-U` alone. There is no way to edit the list afterwards from `security` — cleaning up
duplicates means deleting and recreating the entry.

**`add-generic-password` without `-U` refuses an existing account**, exiting 45 and leaving the
stored value untouched. That is why `login` branches on `in_keychain` before writing: the `-T` path
it takes for a new entry would otherwise die on a name already in the keychain, and `set -e` would
take the script with it. The exit codes and output of every `security` call this script makes are
tabulated under "What `security` is assumed to do" in [`../SPEC.md`](../SPEC.md).

## `gh` commands

**`gh config set -h <host> <key> <value>` writes into the active user's entry**, not the host level.
The script therefore writes the `hosts.yml` skeleton directly. Do not reintroduce `gh config set`.

**`gh auth logout` leaves the Keychain secret intact.** It removes the name from `hosts.yml` and
switches away, but the stored value stays readable — verified against both an oauth entry and a
classic PAT, so it does not depend on the token type. Every such logout therefore produces an orphan,
and for a PAT that orphan is a working credential with nothing referencing it.

`login` treats such an entry as free to take: `in_keychain` still decides whether `-T` is passed,
since that is about the ACL on an item that exists, but the overwrite confirmation keys off `has`
instead. Asking "already exists, overwrite?" about an entry `list` just called unusable puts the two
commands at odds over the same alias.

This is why `logout` lists orphans alongside registered aliases: `gh` has dropped the name, so
`gh auth logout` cannot reach the entry any more, and this is the only place left that can. The menu
is built registered-first and `SEL_IDX >= registered` identifies an orphan — it has no `hosts.yml`
line to delete and cannot be the active account, so removal touches only the Keychain. Orphans also
skip the oauth warning: `gh` already ended that session, which is how the entry became an orphan.

User-facing text calls this state **`keychain only`**, never "orphan" — the code keeps the shorter
word for `orphans()` and `is_orphan`, but nothing printed uses it. Earlier wordings were rejected for
implying the wrong action: `ORPHAN` is jargon, and `UNREGISTERED` suggests re-registering is an
option when deletion is all there is. A `MENU_NOTE` line above the menu spells the state out, set
only when such an entry is listed, and limited to one line by `note_lines` — the collapse arithmetic
depends on that count. That line states the consequence ("cannot be used to log in") rather than the
mechanism ("gh no longer knows the name"): the mechanism only means something to someone who already
knows `hosts.yml` drives enumeration.

**`gh auth setup-git` registers a credential helper, not a token.** It is once per host, not per
account, and the helper resolves the active account at push time. The script does not call it.

**`gh auth switch` reports success on stderr.** `>/dev/null` alone leaves "✓ Switched active account
for github.com to X" on screen, right next to the line this script prints about the same thing. Every
call needs `2>&1`. `gh api` in a `$(...)` has the mirror problem: the substitution captures stdout,
so a failure prints its message straight into the middle of whatever line is being assembled.

**`gh auth login --with-token` calls the API to resolve the login name**, which is both why it needs
network access and why it cannot be used with GitHub App installation tokens.

## Token validation

**Token validation calls the API directly, not through `gh`.** `login` and `rotate` check a pasted
token before storing it — the prefix first, then `GET /user` for a 200 — because `read -rs` makes the
paste invisible, so a truncated or wrong value is otherwise only discovered later as an alias that
exists but cannot authenticate. This deliberately does not go through `gh auth login --with-token`:
that would key the entry by the login name it reads back and overwrite any other alias for the same
account. `token_login` is a plain `curl` and leaves `gh`'s state alone; it sets `TOKEN_LOGIN`, which
the success line then reuses instead of asking again.

A failed check re-prompts instead of exiting, so both call sites wrap the prompt in a `while true`.
In `rotate` that nests inside the alias loop, where a bare `continue` would retry rather than advance
— hence the `skip` flag and `$skip && continue` after the inner loop. Empty input is the way out of
both: cancel in `login`, skip this alias in `rotate`.

## Outside this script

**The `hosts.yml` layout is assumed outside this script too.** The Powerlevel10k recipe in the README
parses `    user: ` inline rather than calling `gh pat current`, because p10k discourages forking a
subprocess on every prompt — and going through `gh` means two process starts, not one. It carries the
same four-space indentation assumption as `active()`, so a layout change in `gh` means fixing both.
