# CLAUDE.md

Guidance for working in this repository.

## What this is

`gh-pat` is a single bash script (`./gh-pat`) distributed as a `gh` extension. It registers multiple
GitHub tokens under arbitrary **aliases** so that several tokens can coexist for the same account —
something `gh auth login` cannot do, because it keys stored credentials by the login name it reads
back from the API.

There is no build step and nothing to install. `test.sh` covers what can be checked without a
Keychain or a terminal; the rest is a manual checklist. The script is the product.

## Repository layout

```
gh-pat        the script — everything lives here
test.sh       checks the script against SPEC.md
tests/        what test.sh needs but does not run directly
README.md     user-facing docs
SPEC.md       what each command must do — the contract, not the implementation
docs/         how to work on it — see below
CLAUDE.md     this file
```

`SPEC.md` is the one to change first when behavior changes. It states the intended contract, so a
disagreement between it and the script is a bug in the script unless the spec says otherwise —
without that rule, tests written against the code would simply freeze whatever it does today.

## Read these first

`docs/` holds what anyone working on the script needs, whether or not they are an agent. Do not
restate any of it here — link to it.

- [`docs/platform-constraints.md`](docs/platform-constraints.md) — bash 3.2, BSD tools, `set -e` and
  arithmetic, and the rules on file count, dependencies, and token handling. **Read before writing
  any code.** Violating one produces a script that passes review and fails on a real machine.
- [`docs/undocumented-behavior.md`](docs/undocumented-behavior.md) — everything about `gh` and
  `security` this tool relies on that neither documents. Read before changing anything that touches
  `hosts.yml`, the Keychain, or a `gh` subprocess.
- [`docs/verifying-a-change.md`](docs/verifying-a-change.md) — what `test.sh` covers, what it cannot,
  and the table of manual checks.
- [`docs/design-notes.md`](docs/design-notes.md) — UI conventions, why prompts read `/dev/tty`, and
  the reasoning behind `rotate`.

## Making changes

The script is a flat sequence of sections marked with `# ---------------- name ----------------`.
Adding a subcommand means touching four places, in this order:

1. The header comment block below the shebang — this is the usage text, printed verbatim
   (the blank line after the summary is a bare `#`; the one at the end comes from `usage()`)
2. The `sed -n '2,Np'` range inside `usage()` — bump `N` to match the new last line
3. The `case ${1-} in` dispatch. A subcommand with no options is then covered for help by
   the `${2-}` check below it; one that parses options answers `-h`/`--help` in its own
   loop instead, the way `rotate` does
4. A new section placed after the helper function definitions and before `# ---- list ----`

Forgetting step 2 silently truncates the help output.

Helper functions (`aliases`, `active`, `has`, `in_keychain`, `token_kind`, `standard_format`) are
defined after `usage()` and before the dispatch. Anything that calls them must come after.

## Reporting on a change

Say what was actually run and what was only reasoned about, separately. A sandbox has no Keychain, no
tty, and no network, so a large share of this tool's behavior cannot be verified from one — and
presenting inference as observation makes it impossible to tell which claims to trust. When a check
needs something the sandbox lacks, ask the user to run it rather than arguing from the code; the
table in [`docs/verifying-a-change.md`](docs/verifying-a-change.md) says which check needs what.

The same applies to these documents. Write the mechanism or the number, not the verdict — a sentence
that reads like a finding but was never measured cannot be checked later.
