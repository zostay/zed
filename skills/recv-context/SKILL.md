---
name: recv-context
description: Read a context handoff Markdown file written by `send-context` from another Claude Code session, absorb it into the current session, then delete the file.
---

# Receive Context

Pick up a one-way context handoff written by the companion `send-context` skill in another Claude Code session. Read the file, internalize its contents so the current session can continue the work, then delete the file so it is not consumed twice.

## Argument

The skill takes an optional argument: where to find the handoff file.

- If no argument is given, look in the **current working directory** for `claude-context-handoff.md`.
- If the argument is a directory, look inside that directory for `claude-context-handoff.md`.
- If the argument is a file path (relative or absolute), use it directly.
- If multiple files matching `claude-context-handoff*.md` exist in the target directory (e.g., timestamped variants from `send-context`), list them with their modification times and ask the user which one to consume. Do not guess.

The user may also pass the flag `--keep` or `-k` to instruct the skill **not** to delete the file after reading. The flag must appear as a **standalone whitespace-separated token** in the argument string — do not match it as a substring. A path like `~/keep-notes/` or `./my-keep-file.md` does **not** count as the flag.

## Steps

### 1. Locate the file

Resolve the path per the rules above. If the file does not exist, report the absolute path that was checked and stop. Do not search the filesystem broadly.

### 2. Read the file

Read the entire file with the `Read` tool. If it is larger than a few hundred lines, that is unusual for a handoff — read it anyway, but note the size in your report.

### 3. Sanity-check the format

A well-formed handoff begins with a YAML frontmatter block containing **at least** these two fields, with these exact values:

```yaml
format: claude-context-handoff
version: 1
```

This marker is mandatory. It is what distinguishes a handoff from any other Markdown file the receiver might be pointed at by mistake.

**Hard requirement before deletion:** if the file does not contain a valid frontmatter block with `format: claude-context-handoff`, refuse to delete it under any circumstances — even if the user passed an explicit path. Stop, tell the user what file was found and why it was rejected, and let them decide.

If the marker is present but `version` is something other than `1`, the file was written by a newer (or different) `send-context`. Read it anyway on a best-effort basis, but flag the version mismatch in your briefing and ask the user whether deletion is still appropriate.

If the marker is present and the version matches, also sanity-check that the body contains most of: Goal, Current state, Decisions and constraints, Open questions and next steps, Pointers. A handoff missing all of these is suspicious — surface that, but the marker is still authoritative for the deletion decision.

If `generated_at` is suspiciously old (more than a few days, where applicable), flag this to the user — the state described in the file may have drifted.

### 4. Absorb the content

Read the handoff carefully and treat its contents as authoritative session context going forward:

- The **Goal** becomes the working objective for this session unless the user redirects.
- **Decisions and constraints** should be respected as if the user had stated them in this session. Do not re-litigate decisions that were already settled in the sending session.
- **What NOT to do** items are hard constraints — honor them.
- **Open questions** are things to surface back to the user near the start of the next response.
- **Pointers** to files on the *originating* machine may not be accessible here. Note which pointers resolve to files that exist in the current environment and which do not.

### 5. Reconcile with the current environment

The receiving session is in a different working directory and possibly a different repo. Before acting on the handoff:

- Run `pwd` and, if in a git repo, `git rev-parse --show-toplevel`, `git branch --show-current`, `git status --short` to understand where you are.
- Compare with the handoff's "originating working directory" / git info. If they differ, that's expected for a cross-project handoff — note it but proceed.
- If the handoff references uncommitted changes in the originating repo and the current repo does not have them, the user will need to bring those over separately (patch, push/pull, etc.). Flag this; do not try to recreate the changes from the summary.

### 6. Report to the user

Produce a short briefing for the user covering:

- Where the handoff came from (originating directory, branch, timestamp).
- A one-paragraph restatement of the goal.
- The top 3–5 things the receiving session should do or watch for, drawn from "next steps", "open questions", and "what not to do".
- Any open questions from the handoff that need user input before proceeding.
- Anything in the handoff that looks stale, contradictory with the current environment, or that you could not verify.

Keep this briefing tight — a dozen lines or so. The user wrote the handoff; they don't need it read back to them verbatim.

### 7. Delete the file

Unless `--keep` was passed, **and** the format marker from step 3 validated, delete the handoff file. Always quote the path and use `--` to terminate option processing, so paths containing spaces or beginning with `-` are handled safely:

```bash
rm -f -- "<path-to-handoff>"
```

Use `rm -f` so a missing file is not an error. Report the deletion in one line.

If `--keep` was passed, skip deletion and tell the user the file was preserved at its path.

If the format marker did not validate in step 3, do **not** delete the file regardless of any `--keep` setting — the receiver has no reason to be confident the file is actually a handoff.

### 8. Continue

Wait for the user's next instruction, or — if the handoff's "next steps" section names a clear first action and the user has authorized autonomous continuation — begin that action. When in doubt, surface the open questions first and let the user choose.

## Notes

- The handoff is a one-way baton. Once deleted, it is gone. If the user later realizes they needed to re-read it, they will have to ask the sending session to regenerate one.
- Do not write to the handoff file or modify it before deletion. If you noticed an error in it, mention that in your briefing instead.
- Do not create a *new* handoff file from this session as a side effect of receiving one. Use `send-context` explicitly for that.
