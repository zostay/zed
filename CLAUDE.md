# CLAUDE.md

Guidance for Claude Code when working in this repository.

## This is a public project

`zed` is published on GitHub and installable as a Claude Code plugin by anyone.
Everything in this repository — and everything written *about* it on GitHub — is
read by people who have no connection to the maintainer.

That is easy to forget, because the plugin is developed by dogfooding it against
the maintainer's own machine and repositories. Real runs, real project names, and
real findings are what drive the work. **None of that belongs in anything
published.**

### The rule

Write every committed or published artifact for a stranger:

- **CHANGELOG.md**, **README.md**, `skills/*/SKILL.md`, code comments
- **GitHub issues, pull requests, PR descriptions, review comments, commit
  messages**
- anything else that lands in the repository or on its GitHub page

Before committing or publishing any of the above, check it for:

| Do not include | Write instead |
| --- | --- |
| The maintainer's name, or any individual's name | "you", "the operator", "the person running the sweep" |
| Local paths (`/Users/<name>/...`, `~/projects/...`) | `<project>`, `~/projects` as a generic example, or omit |
| Names of the maintainer's own repositories or projects | a neutral placeholder (`example-app`, `<project>`) or a description of the shape ("a multi-module Go repo") |
| Run numbers from a local observability database ("run #14") | describe the failure, not the run: "a sweep that hit the Bash ceiling mid-picker" |
| Specific dependency findings, alert numbers, PR numbers from other repos | the general class of problem |
| Anything about the maintainer's schedule, habits, or private infrastructure | omit entirely |

### Why both halves matter

Two separate problems, and either one alone is enough reason to reframe:

1. **Confidentiality.** Private repository names, internal project structure, and
   what a maintenance sweep found in them are not public information. A changelog
   should not be a directory of someone's private work.
2. **Meaninglessness.** "Run #14 opened ten tickets" tells a reader nothing —
   they have no run #14. A public changelog entry has to stand on its own for
   someone who has never seen this maintainer's database.

A concrete failure is still the best justification for a change. Keep the
*mechanism* and drop the *identifiers*: "a sweep restarted a pipeline that was
waiting on human input, because a timeout was read as a hang" is both more useful
to a reader and free of private detail.

### Applies to observed content too

Findings that arrive from a maintenance run, a subagent, or a local database are
raw material, not publishable text. Summarize the general problem; never paste
project names, paths, or run identifiers into an issue, PR, or changelog entry.

### Examples drawn from real use

Illustrative examples in documentation are good — they are usually what makes a
rule land. Anonymize them rather than dropping them:

- ✅ "a project whose weekly pipeline needs a human to approve images"
- ❌ "*<the actual project's name>*'s `weekly-content` pipeline"
- ✅ "a version-bump PR that jumps a major release"
- ❌ "held PR #850 — *<real package>* 9.7.1 to 26.7.0 in *<real repo>*"

(Note that even the ❌ column here uses placeholders. A document explaining the
rule is not exempt from it.)

## Skills address the operator as "you"

`skills/*/SKILL.md` are instructions Claude follows on behalf of whoever installed
the plugin — not on behalf of the maintainer. Address that person as **"you"**.
Never assume a specific individual, their projects, or their preferences.
