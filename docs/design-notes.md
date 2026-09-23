# Design notes

Why parts of the script look the way they do. [`../SPEC.md`](../SPEC.md) states what the commands
must do; this file records the reasoning behind how they do it, so a change does not undo a decision
without knowing it was one.

## UI conventions

Output imitates `gh`'s survey prompts: a green `?` marker, a bold question, cyan for values and
answers, dim for hints. Use the `tip`/`ok`/`err`/`warn`/`ask`/`ask_secret` helpers rather than raw
`printf` so `NO_COLOR` and non-TTY output keep working.

`warn` (yellow `⚠`) is for something the reader should know while the command carries on; `err`
(red `✗`) always precedes a stop. Mixing them reads badly — a `✗` followed by a success line looks
like a contradiction.

All user-visible strings are English, including in a Korean-language conversation.

`gh pat <cmd> --help` arrives as a plain argument, so every subcommand has to answer it itself —
`gh` does not intercept the flag. Getting this wrong is quiet rather than loud: a command that reads
no arguments runs normally and ignores the flag, and an interactive one opens a prompt in response to
a request for help.

`menu_select` collapses the prompt, an optional `MENU_NOTE` context line, and the menu into one
answered line when it finishes. The cursor arithmetic is `n + note_lines + 1`; changing what gets
printed before the loop means changing that sum. `MENU_NOTE` is cleared by the function, so callers
set it immediately before each call.

## Prompts read from `/dev/tty`

`ask` and `ask_secret` do this explicitly because the alias loops use `done < <(aliases)`, which
rebinds stdin for the whole loop body — a plain `read` there consumes the alias stream instead of
user input and returns EOF immediately. The cost is that both now fail outright where there is no
controlling terminal, which is why `rotate` checks `[[ -t 0 ]]` before it starts: otherwise the
failure surfaces as a raw `/dev/tty: Device not configured` partway through the loop, after the
expiry lookups have already hit the API.

## Rotation

`rotate` only rewrites Keychain values; `hosts.yml` is not touched, because rotating a token does
not change which aliases exist. It is the one subcommand that takes options, so it parses `$@` in a
loop rather than testing `${2-}`; `ROTATE_DAYS` stays `readonly` as the default and `--days` writes
to a separate `days_max`. Options are validated before the `[[ -t 0 ]]` check so that a typo is
reported as a typo even with no tty to report it to.

`rotate` opens by stating its filter — the threshold, or that `--all` is in effect — because the skip
lines that follow are verdicts, and without the rule in view the default threshold is invisible.
Nothing separates that line from the skip list: each rotate candidate prints its own leading newline,
so a blank line after the criterion doubles up whenever the first alias is a candidate rather than a
skip — which is every alias under `--all`.

That line doubles as the `--days`-with-`--all` warning, so the two stay in one `if` rather than
printing twice. The warning branch tests `days_max != ROTATE_DAYS`, which means `--days 15 --all` —
the default spelled out explicitly — reads as a plain `--all`. Catching that would take a separate
"was --days given" flag, which is not worth the extra state.

### Expiry classification

Expiry comes from the `github-authentication-token-expiration` response header — `gh auth status`
does not expose it, and a non-expiring classic PAT omits the header rather than returning a null.

Four outcomes have to stay distinct, and an empty header alone cannot tell them apart: **no expiry**
(a real property of classic PATs), **an expiry date**, **rejected**, and **lookup failed**.

A rejected token (401, or a 403 that is not rate limiting) is offered for replacement even below the
threshold, because it is already useless — skipping it is how a dead token stays dead. `403` cannot
be lumped in with `401`: GitHub returns it for an exhausted rate limit too, where the quota is spent
but the secret is fine, so the branch checks `x-ratelimit-remaining` and treats `0` as lookup failed.
A missing `x-ratelimit-remaining` on a 403 means a permission or SSO problem, which does belong with
rejected. That is why the request captures the status code via `-D - -w '%{http_code}'` and treats
anything but 200 as unknown — an unreachable network and a 401 both return no header, and reporting
either as "no expiry" silently skips a token that may be days from expiring. Unparseable dates fold
into the same unknown state. Unknown is skipped like the others but printed in red and counted into
the closing summary.

The `date -j -f` call is BSD-specific: `%Z` is not a supported input format, so the trailing zone is
stripped and `TZ=UTC` is forced instead. This assumes the header always says `UTC`; a numeric offset
would parse without error and be off by that offset. Verify against a token with a known expiry date
after touching any of this.
