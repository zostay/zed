---
name: send-context
description: Summarize the current Claude Code session's context and write it to a handoff Markdown file so another Claude Code session can pick up the work.
---

# Send Context

Capture the substance of the current conversation — what the user is trying to accomplish, what has been learned, what has been decided, what is still open — and write it to a Markdown file that another Claude Code session (in a different project, machine, or worktree) can read with the companion `recv-context` skill.

This is a one-way handoff. The receiving session will consume and delete the file by default. Treat the file as a baton, not a shared log.

## Argument

The skill takes an optional argument: the destination folder or file path where the handoff file should be written.

- If no argument is given, write to the **current working directory**.
- If the argument looks like an absolute path, use it as-is.
- If the argument looks like a relative path or bare folder name, resolve it relative to the current working directory.
- If the argument names a path that does not exist, ask the user whether to create it or abort. Do not silently `mkdir -p` a path the user may have mistyped.
- If the argument names a file (not a directory), treat the parent as the destination and use the filename as-is, overriding the default filename below.

## Filename

Default filename: `claude-context-handoff.md`.

If a file with that name already exists in the destination, do **not** silently overwrite. Show the user the existing file's first heading and modification time and ask whether to overwrite, append a timestamp suffix (e.g. `claude-context-handoff-2026-05-13-1432.md`), or abort.

## What to capture

Before writing, take stock of the conversation. The goal is that a fresh Claude session reading this file alone — with no access to this transcript — could continue the work without re-asking the user the obvious questions.

Include, in this order:

### 0. Marker frontmatter (required, machine-checkable)

The file **must** begin with a YAML frontmatter block that `recv-context` can validate before deleting the file. This is what distinguishes a handoff file from any other Markdown file that happens to share its filename or section names. Use exactly these keys:

```markdown
---
format: claude-context-handoff
version: 1
generated_at: <ISO 8601 timestamp with timezone offset>
originating_cwd: <absolute path of the current working directory>
originating_repo: <git toplevel absolute path, or null if not in a repo>
originating_branch: <current git branch, or null>
originating_commit: <short SHA, or null>
subject: <one-sentence subject line of the handoff>
---
```

`format: claude-context-handoff` and `version: 1` are the load-bearing fields — `recv-context` requires both to match before it will delete the file. Do not rename or omit them. If the spec ever changes incompatibly, bump `version`.

### 1. Header

A short prose header below the frontmatter restating the subject line and any context the frontmatter can't carry (e.g., "this handoff is the third in a series — see also …"). One paragraph.

### 2. Goal

What the user is ultimately trying to do. Two to five sentences. Not a step list — the *why*.

### 3. Current state

What has been done so far in this session. Be specific: name files, functions, commands run, tests passing or failing. Distinguish committed changes from working-tree changes from purely-discussed-but-not-yet-implemented decisions.

If there are uncommitted changes in the originating repo, summarize `git status` and `git diff --stat` so the receiver knows what is in flight. Do not paste full diffs — point to the files.

### 4. Decisions and constraints

Non-obvious choices the user has made or agreed to during the session: library picks, naming conventions, things explicitly rejected, deadlines, stakeholder asks. Include the *reason* for each so the receiver can judge edge cases. This is the highest-value section — err on the side of including too much here.

### 5. Open questions and next steps

What the next session should do first. If there are open questions for the user, list them so the receiver knows to ask before acting. If there are concrete next actions, list them in order.

### 6. Pointers

Files, URLs, PR/issue numbers, dashboards, docs, or external systems the receiver will need. Use absolute paths for anything on the originating machine; the receiver may not have access to those, but it should know they exist.

### 7. What NOT to do

If the user has explicitly ruled anything out, or if there are landmines (flaky test, do-not-touch file, in-progress migration), call them out here. This section can be empty — only include it if there is real content.

## What to leave out

- Do not paste large file contents or full diffs. Reference the path; the receiver can read the file if it has access, or ask the user to share it if it does not.
- Do not include secrets, tokens, credentials, or `.env` contents. If any appeared in the conversation, note that they exist and where to find them, but do not transcribe them.
- Do not narrate the conversation turn-by-turn. Summarize state, not history.
- Do not include things derivable from the code or `git log` in the receiving project. If the handoff target is the *same* repo on a different machine, the receiver can read the repo itself — don't duplicate.

## Style

Write the file so a cold reader can pick it up. Complete sentences, no shorthand from this transcript, no unresolved pronouns ("it", "that thing"). Use Markdown headings matching the sections above. Keep the whole file under ~400 lines; if it would be longer, you are including too much detail — tighten.

## Steps

1. Resolve the destination path from the argument (or default to `pwd`). Verify it exists or confirm creation with the user.
2. Determine the final filename, handling existing-file collisions as described above.
3. Gather the metadata: timestamp, working directory, git info, working-tree status.
4. Build the marker frontmatter block (section 0). This block is required.
5. Draft the remaining sections from conversation context. If a section would be empty or trivial, omit it (except the frontmatter, header, and goal, which are required).
6. Write the file with the `Write` tool.
7. Report to the user: the absolute path of the file, its line count, and a one-line confirmation of what was captured. Do not paste the file's contents back into the conversation.

## After sending

Do not delete or modify the file from this side — the receiver owns its lifecycle. Continue the current session normally; sending a handoff does not end this session.
