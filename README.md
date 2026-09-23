# gh-pat

A `gh` extension that keeps multiple tokens for the same GitHub account under local aliases, stored
in the macOS Keychain.

`gh` keys stored credentials by the account name it reads back from the API, so logging in twice
with the same account just overwrites the first token. `gh-pat` sidesteps that by treating the
`users:` key in `hosts.yml` as an arbitrary **alias** — a lookup key for the Keychain rather than a
real username. That makes it possible to keep several tokens for the same account (say, one classic
and one fine-grained) and switch between them the same way you would switch accounts.

```
$ gh pat list
* work                       fine-grained
  work-classic               classic
  personal                   fine-grained
```

## Why not `gh auth login`?

| | `gh auth login` | `GH_TOKEN` | `gh-pat` |
| --- | --- | --- | --- |
| Multiple accounts | yes | yes | yes |
| **Multiple tokens for one account** | no | yes | yes |
| Token storage | Keychain | wherever you put it | Keychain |
| Works with `git push` | yes | not via the credential helper | yes |
| Survives a new shell | yes | no | yes |

Classic and fine-grained tokens are not interchangeable — some APIs still require classic scopes,
and fine-grained tokens are scoped per repository. Keeping both registered avoids re-authenticating
every time you cross that line.

## Requirements

- macOS (uses `security` and BSD `sed`)
- [`gh`](https://cli.github.com) 2.40 or newer (multi-account support)
- bash 3.2 or newer (the system bash is fine)

## Install

```bash
gh extension install khw1006/gh-pat
gh pat list
```

Upgrading:

```bash
gh extension upgrade pat
```

## Usage

```
gh pat login    register or update a token
gh pat logout   remove a token
gh pat rotate   replace tokens that are close to expiry
                --days N to change the 15-day threshold, --all for every alias
gh pat switch   change the active account
gh pat list     list aliases and verify consistency
gh pat current  print the active alias (for shell prompts)
```

`-h` or `--help` prints this list, after any subcommand.

### `login`

Prompts for an alias and a token, checks the token, writes it to the Keychain, registers the alias in
`hosts.yml`, and activates it.

```
$ gh pat login
Alias is a local label for this token — it is only used as the keychain lookup key.
It does not have to match your GitHub username, so you can register several tokens
for the same account (e.g. one classic, one fine-grained).
Examples: work, personal, classic, ci, readonly

? What alias would you like to use for this token? work-classic

Generate a token at https://github.com/settings/tokens
Scope it to whatever you intend to do with it — gh-pat only stores what you paste.
? Paste your authentication token:
✓ Logged in as work-classic [classic] account=octocat
```

`account=` shows the real GitHub login the token belongs to. It will differ from the alias — that
is the point.

The token is checked before it is stored: the prefix has to look like a GitHub token, and the API
has to accept it. A failed check asks again rather than starting over — the alias is already chosen.
Press Enter on an empty prompt to cancel.

```
$ gh pat login
? What alias would you like to use for this token? work-classic
? Paste your authentication token:
✗ Not a GitHub token — expected ghp_, gho_, ghu_, ghs_, or github_pat_
Try again, or press Enter to cancel.
? Paste your authentication token:
✓ Logged in as work-classic [classic] account=octocat
```

This matters because the paste is invisible — `login` reads it with `read -rs` so the value never
reaches the scrollback. Without the check, a truncated paste is stored happily and only surfaces
later as an alias that exists but cannot authenticate.

Running `login` against an existing alias asks before overwriting, which is how you rotate a token.
An alias marked `keychain only` is reused without asking — `gh` cannot log in with it, so there is
nothing in use to replace.

Picking an alias equal to the token's own GitHub login asks before going ahead:

```
⚠ 'octocat' is this token's own account name.
gh auth login writes to that same keychain entry, so a browser login would
replace this token silently. A different alias keeps the two apart.

? Use 'octocat' anyway? [y/N]
```

`gh` stores browser logins under the account name it reads back from the API — the same keychain
entry an identical alias would use. Answering `y` is a fair choice for one person with one account;
it just means the two are sharing one slot. `work` and `work-classic` sidestep it entirely.

### `switch`

Arrow-key picker. The currently active alias is shown as context, marked with `*` as in `list`, and
excluded from the list.

```
$ gh pat switch
? Which alias do you want to activate? (use ↑/↓ to navigate, Enter to select, q to cancel)
* work                       [fine-grained]
❯ work-classic               [classic]
  personal                   [fine-grained]
```

With only two aliases registered there is nothing to choose between, so `switch` goes straight to the
other one:

```
$ gh pat switch
✓ Active account is now work-classic [classic] account=octocat
```

### `logout`

Same picker, then a confirmation. If you remove the active alias, another one is activated first so
`hosts.yml` never points at a missing entry.

Entries holding an `oauth` or `app` token get a warning first — those came from `gh auth login`, not
from here, and removing one ends that session:

```
⚠ 'octocat' holds a token gh-pat did not store.
It came from gh auth login, and removing it ends that session.
gh auth logout -h github.com -u octocat is the matching command.
```

Entries marked `keychain only` appear in the same picker, and removing one deletes just the Keychain
entry:

```
? Which alias do you want to remove? (use ↑/↓ to navigate, Enter to select, q to cancel)
  keychain only — the token is still stored but cannot be used to log in
❯ work                       [fine-grained] (active)
  old-ci                     [classic] keychain only
```

They skip the warning above — `gh auth logout` already ended that session, which is what left the
entry behind.

### `rotate`

Walks the aliases whose tokens are close to expiry and prompts for a replacement. Press Enter to
skip one.

```
$ gh pat rotate
Tokens expiring within 15 days.
  personal                   expires in 92d — skipped
  work-classic               no expiry — skipped

  work  [fine-grained]  expires in 12d
? New token (Enter to skip):
✓   updated work [fine-grained]

✓ Rotated 1 token(s).
```

The first line states the criterion, so the skip lines below it read as verdicts against a rule you
can see rather than an unexplained filter.

Expiry is read from the response header GitHub returns for the token, so this needs network access.
A classic PAT created without an expiry date has no header at all and is reported as `no expiry`.

A token the API outright rejects is offered for replacement regardless of the threshold — it is
already useless, so there is nothing to wait for:

```
$ gh pat rotate
Tokens expiring within 15 days.
  personal                   expires in 92d — skipped

  work-classic  [classic]  REJECTED — the API does not accept this token
? New token (Enter to skip):
```

When the expiry cannot be read at all — no network, a server error, or an exhausted rate limit — the
alias is reported as `expiry unknown` and skipped, and the count is repeated at the end. This is
deliberately distinct from both of the above: `no expiry` is a property of the token, `REJECTED` is a
verdict on it, and this is a question that went unanswered. A token that could not be checked is not
assumed bad.

```
$ gh pat rotate
Tokens expiring within 15 days.
  work                       expiry unknown — skipped

✗ 1 alias(es) could not be checked — network or token error.
```

The default threshold is 15 days. `--days` changes it, and `--all` ignores it entirely and walks
every alias:

```bash
gh pat rotate --days 7      # only what expires within a week
gh pat rotate --days 90     # a wider sweep, e.g. before going on leave
gh pat rotate --all         # every alias, whatever its expiry
```

`--all` overrides `--days` rather than combining with it, and the opening line says which rule is in
effect:

```
$ gh pat rotate --all
Every alias, whatever its expiry.

$ gh pat rotate --days 7 --all
Every alias — --all ignores --days 7.
```

Only the stored secret changes — the alias, and anything referencing it, stays as it is.

Replacements are checked the same way `login` checks them, and a failed check leaves the alias
untouched — a rejected token beats a corrupted one. It also asks again for the same alias rather
than moving on; Enter skips to the next one:

```
  work-classic  [classic]  REJECTED — the API does not accept this token
? New token (Enter to skip):
✗   the API does not accept that token — work-classic left unchanged
? New token (Enter to skip):
✓   updated work-classic [classic] account=octocat
```

GitHub has no API for creating personal access tokens, so the token itself still has to be generated
at <https://github.com/settings/tokens> and pasted in. For fine-grained tokens, use **Regenerate** on
an existing token rather than creating a new one: regeneration keeps the same permissions and
resource owner, so an organization that requires approval does not have to approve it again.

### `list`

Shows every registered alias with its token type. `*` marks the active one. A healthy row stops
there; anything further along the line is a problem worth knowing about:

```
$ gh pat list
* work                       fine-grained
  work-classic               classic
  gone                       -              MISSING keychain
  stray                      classic        keychain only
```

- `MISSING keychain` — the alias is in `hosts.yml` but has no Keychain entry, so the token type
  cannot be read either
- `keychain only` — the token is still in the Keychain but no alias refers to it, so `gh` cannot use
  it to log in
- `nonstandard format` — the value is stored without the prefix `gh` writes. It still works today
  through a fallback in `gh`'s keyring library, but nothing here or in `gh` produces one, so
  something else wrote to that entry directly

Every `gh auth logout` leaves one of these: it drops the name and switches away but does not touch
the stored secret. For a PAT that means a working token sitting in the Keychain with nothing pointing
at it, so `logout` offers them for removal too.

## Prompt integration

`gh pat current` prints the active alias and nothing else, so it drops straight into a prompt.
Because the active account is global, seeing it before you push is the cheapest way to avoid
committing from the wrong identity.

Powerlevel10k is the exception. Its whole design is built around never forking during prompt
rendering, so the recipe below reads `hosts.yml` inline instead of calling `gh pat current`.

### Powerlevel10k

Add this to `~/.p10k.zsh`, above the closing `(( ! $+functions[p10k] )) || p10k finalize` line:

```zsh
# gh-pat: show the active alias only when it is not the default
typeset -g GHPAT_DEFAULT=your-usual-alias

function prompt_ghpat() {
  local f=${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml
  [[ -r $f ]] || return
  local content=$(<$f)
  [[ $content =~ $'\n    user: ([^\n]+)' ]] || return
  local a=$match[1]
  [[ $a == $GHPAT_DEFAULT ]] && return
  p10k segment -f 208 -i '' -t "$a"
}
```

Then register it next to `vcs`, where your eye already goes before a push:

```zsh
typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
  os_icon
  dir
  vcs
  ghpat
  newline
  prompt_char
)
```

Reload with `p10k reload`.

**The segment is hidden while `GHPAT_DEFAULT` is active.** That is the point — a marker that is
always on becomes background noise, and this one needs to be noticed. Remove the
`[[ $a == $GHPAT_DEFAULT ]] && return` line to show it unconditionally.

### Starship

```toml
# ~/.config/starship.toml
[custom.ghpat]
command = "gh pat current"
when = "git rev-parse --is-inside-work-tree"
format = "[$output]($style) "
style = "cyan"
```

### Plain zsh

```zsh
# ~/.zshrc
precmd() { GHPAT="$(gh pat current 2>/dev/null)" }
setopt prompt_subst
PROMPT='${GHPAT:+[$GHPAT] }'$PROMPT
```

Running this on every prompt means starting `gh`, which then starts the extension — two processes to
read one line out of a small file. It is fine on a warm cache and noticeable when things are slow. If
the prompt drags, either cache it in a `chpwd` hook instead of `precmd`, or read `hosts.yml` inline
the way the Powerlevel10k recipe above does.

## How it works

Two pieces of state, kept in sync:

```
~/.config/gh/hosts.yml          which aliases exist, and which one is active
Keychain: gh:github.com         one generic-password entry per alias, keyed by account
```

`gh` enumerates the `users:` map in `hosts.yml` and looks up each name in the Keychain. It never
validates that a name is a real GitHub account, so any label works. Tokens are stored the way `gh`
stores them — base64 with a `go-keyring-base64:` prefix — and the Keychain entry is created with
`-T /usr/bin/security` so `gh` (which shells out to `security` through go-keyring) can read it
without prompting.

`git push` follows along automatically if `gh` is registered as your credential helper. It is not
per-account state — the helper asks `gh` for the active account's token at push time:

```bash
gh auth setup-git   # once per host, not once per account
```

## Caveats

**This depends on undocumented behavior.** The `hosts.yml` layout and the Keychain value format are
internal to `gh`. A future release could change either. If authentication breaks after a `gh`
upgrade, compare against an entry created by `gh auth login` and adjust `PREFIX` accordingly.

**`gh auth status` will show aliases as if they were account names.** To see the real account:

```bash
gh api user --jq .login
```

**Environment variables win.** If `GH_TOKEN` or `GITHUB_TOKEN` is set, `gh` uses it and ignores the
active account entirely. Unset them before troubleshooting.

**The active account is global.** Switching in one terminal changes it everywhere. For genuinely
parallel work, scope a token to a single command instead:

```bash
GH_TOKEN=$(security find-generic-password -s gh:github.com -a work-classic -w \
  | sed 's/^go-keyring-base64://' | base64 -d) gh api /rate_limit
```

**Rotation is a paste, not an automation.** There is no API to mint a PAT, so `rotate` can find what
needs replacing and store the result, but the middle step is manual by design.

**Keychain entries are readable by any process running as you.** This is standard macOS behavior
for generic passwords, not something this tool relaxes. It protects against tokens sitting in plain
text on disk and against access while the session is locked — not against a malicious dependency in
your own shell. Keep broad-scope tokens out of the always-loaded slot and reach for a password
manager when you need one.

**Single host.** Only `github.com` is supported. GHES would need the host to be configurable and a
YAML parser rather than `sed`.

## Contributing

[`SPEC.md`](SPEC.md) states what each command is supposed to do; change it before changing the
script. `./test.sh` checks the script against it and touches nothing outside a temporary directory.

Neither store it touches is the real one: `GH_CONFIG_DIR` points at a fixture and `tests/stub-security`
stands in for the `security` binary, so a run cannot read or write your own credentials. What that
leaves out — anything needing a terminal, a live token, or the real `security` — is a table in
[`docs/verifying-a-change.md`](docs/verifying-a-change.md). Run the ones your change touches before
opening a PR.

Before writing any code, read [`docs/platform-constraints.md`](docs/platform-constraints.md): the
script targets bash 3.2 and BSD tools, and breaking one of those rules produces something that works
on your machine and fails on someone else's. [`docs/undocumented-behavior.md`](docs/undocumented-behavior.md)
records what this tool relies on that `gh` and `security` do not document, and
[`docs/design-notes.md`](docs/design-notes.md) covers the output conventions and the reasoning behind
`rotate`.
