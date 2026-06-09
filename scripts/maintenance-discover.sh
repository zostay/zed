#!/usr/bin/env bash
#
# maintenance-discover.sh — discover projects that define a maintenance-<tag> skill.
#
# Usage: maintenance-discover.sh <tag>
#
# Finds every project under the configured search roots that defines a skill named
# maintenance-<tag>. A project "defines" the skill if either of these files exists:
#   <project>/.claude/skills/maintenance-<tag>/SKILL.md   (project-level skill)
#   <project>/skills/maintenance-<tag>/SKILL.md           (plugin-style layout)
#
# The project root is the directory containing that path (the suffix is stripped).
# Blocklist entries (from maintenance-config.sh blocklist) cause a discovered project
# to be skipped if its absolute path equals an entry, is inside a blocklisted dir, or
# its basename matches an entry.
#
# Each discovered skill may declare an integer `priority:` in its YAML front
# matter to control execution order: lower runs earlier, higher runs later, and
# the default (no field, or an unparseable value) is 0. Ties break by
# project_path so the order stays deterministic. Example uses: a project that
# needs up-front user interaction sets a negative priority to run first; one that
# redeploys centrally-shared apps sets a positive priority to run last.
#
# A skill may also set `requiresAuthorization: true` in its front matter to mark
# its maintenance as privileged (e.g. a production deployment): the orchestrator
# must not run it unattended without an explicit, out-of-band grant created via
# maintenance-authorize.sh. This is surfaced as a boolean in the output.
#
# Output: JSONL, one object per line, sorted by (priority asc, project_path):
#   {"project_path","project_name","skill_name","skill_path","priority","requires_authorization"}
# If no projects are found, prints an informational line to stderr and exits 0 with
# no stdout. Invalid tag -> usage to stderr, exit 2.

set -euo pipefail

# Guarantee the standard tool directories are reachable even when this script is
# launched from a stripped-down environment (e.g. a subshell whose PATH omits
# Homebrew). A minimal PATH can hide bash/dirname/sqlite3/jq/find/python3 and
# stall the whole sweep. Append so any ordering the caller set still wins.
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"

source "$(dirname "${BASH_SOURCE[0]}")/maintenance-common.sh"

mtnc_require jq
mtnc_require find

usage() {
  cat >&2 <<'EOF'
Usage: maintenance-discover.sh <tag>

  <tag>   Skill tag to discover (matches [A-Za-z0-9._-]+); discovers projects
          defining a skill named maintenance-<tag>.
EOF
}

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"

tag="${1:-}"
if [ -z "$tag" ] || ! printf '%s' "$tag" | grep -Eq '^[A-Za-z0-9._-]+$'; then
  echo "Error: invalid or missing tag." >&2
  usage
  exit 2
fi

skill_name="maintenance-${tag}"

# Load the blocklist into an array (entries are raw; no ~ expansion).
blocklist=()
while IFS= read -r entry; do
  [ -n "$entry" ] && blocklist+=("$entry")
done < <(bash "${SCRIPT_DIR}/maintenance-config.sh" blocklist 2>/dev/null || true)

# Decide whether a project path should be skipped by the blocklist.
# Rules: exact path match, inside a blocklisted directory, or basename match.
is_blocked() {
  local path="$1" base entry
  base="$(basename "$path")"
  for entry in "${blocklist[@]:-}"; do
    [ -z "$entry" ] && continue
    # Exact absolute path match.
    if [ "$path" = "$entry" ]; then
      return 0
    fi
    # Inside a blocklisted directory (entry is a prefix path component).
    case "$path" in
      "${entry%/}"/*) return 0 ;;
    esac
    # Basename match (bare directory name).
    if [ "$base" = "$entry" ]; then
      return 0
    fi
  done
  return 1
}

# Read the integer `priority:` from a SKILL.md's YAML front matter. Scans only the
# leading `---`…`---` block, takes the first `priority:` key, strips a trailing
# comment, surrounding single/double quotes, and surrounding whitespace, then
# validates it as an optionally-signed integer. So `priority: '-100'`,
# `priority: " -100 "`, and `priority: -100` all parse to -100. Anything missing
# or unparseable yields the default priority of 0.
read_priority() {
  local skill_md="$1" val
  val="$(awk '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { infm=1; next }
    infm && $0 ~ /^---[[:space:]]*$/ { exit }
    infm && /^[[:space:]]*priority[[:space:]]*:/ {
      sub(/^[[:space:]]*priority[[:space:]]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/["'\'']/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$skill_md" 2>/dev/null)"
  if printf '%s' "$val" | grep -Eq '^-?[0-9]+$'; then
    printf '%s' "$val"
  else
    printf '0'
  fi
}

# Read the boolean `requiresAuthorization:` from a SKILL.md's YAML front matter.
# Scans only the leading `---`…`---` block. Strips a trailing comment, surrounding
# single/double quotes, and surrounding whitespace (consistent with read_priority),
# then prints the JSON literal `true` when the value is a truthy token
# (true/yes/on/1, case-insensitive) — so `'true'` and `" true "` also count —
# otherwise `false`. Missing or unparseable -> `false`. A project sets this when
# its maintenance does something privileged (e.g. a production deployment) that
# must not run unattended without an explicit grant (see maintenance-authorize.sh).
read_requires_authorization() {
  local skill_md="$1" val
  val="$(awk '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { infm=1; next }
    infm && $0 ~ /^---[[:space:]]*$/ { exit }
    infm && /^[[:space:]]*requiresAuthorization[[:space:]]*:/ {
      sub(/^[[:space:]]*requiresAuthorization[[:space:]]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/["'\'']/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      print tolower($0)
      exit
    }
  ' "$skill_md" 2>/dev/null)"
  case "$val" in
    true|yes|on|1) printf 'true' ;;
    *)             printf 'false' ;;
  esac
}

# Collect discovered project paths keyed to their skill path.
# We store "project_path<TAB>skill_path" lines, then dedupe by project_path.
results_file="$(mktemp)"
trap 'rm -f "$results_file"' EXIT

# For each configured root, search for matching SKILL.md files in both layouts.
while IFS= read -r root; do
  [ -z "$root" ] && continue
  [ -d "$root" ] || continue

  # Find SKILL.md files at the expected relative locations, pruning heavy dirs.
  while IFS= read -r skill_md; do
    [ -z "$skill_md" ] && continue
    project=""
    case "$skill_md" in
      */.claude/skills/"$skill_name"/SKILL.md)
        project="${skill_md%/.claude/skills/$skill_name/SKILL.md}"
        ;;
      */skills/"$skill_name"/SKILL.md)
        project="${skill_md%/skills/$skill_name/SKILL.md}"
        ;;
      *)
        continue
        ;;
    esac
    [ -n "$project" ] || continue
    printf '%s\t%s\n' "$project" "$skill_md" >>"$results_file"
  done < <(
    find "$root" -maxdepth 12 \
      \( -name node_modules -o -name .git -o -name vendor \) -prune -o \
      -type f -name SKILL.md -path "*/skills/${skill_name}/SKILL.md" -print 2>/dev/null
  )
done < <(bash "${SCRIPT_DIR}/maintenance-config.sh" roots 2>/dev/null || true)

# Dedupe by project_path (after `sort -u`, the lexicographically-first skill_path
# for each project_path wins — not discovery order), apply blocklist, read each
# project's priority, sort by (priority asc, project_path), and emit JSONL. The
# intermediate line is "priority<TAB>project_path<TAB>skill_path"; `sort -k1,1n`
# orders numerically by priority and `-k2,2` breaks ties by path deterministically.
emitted=0
output="$(
  sort -u "$results_file" | awk -F'\t' '!seen[$1]++' | \
  while IFS=$'\t' read -r project skill_md; do
    [ -n "$project" ] || continue
    if is_blocked "$project"; then
      continue
    fi
    printf '%s\t%s\t%s\n' "$(read_priority "$skill_md")" "$project" "$skill_md"
  done | sort -t$'\t' -k1,1n -k2,2 | \
  while IFS=$'\t' read -r priority project skill_md; do
    [ -n "$project" ] || continue
    name="$(basename "$project")"
    jq -nc \
      --arg pp "$project" \
      --arg pn "$name" \
      --arg sn "$skill_name" \
      --arg sp "$skill_md" \
      --arg pr "$priority" \
      --argjson ra "$(read_requires_authorization "$skill_md")" \
      '{project_path: $pp, project_name: $pn, skill_name: $sn, skill_path: $sp, priority: ($pr|tonumber), requires_authorization: $ra}'
  done
)"

if [ -n "$output" ]; then
  printf '%s\n' "$output"
  emitted=1
fi

if [ "$emitted" -eq 0 ]; then
  echo "No projects defining '${skill_name}' found under the configured search roots." >&2
  exit 0
fi
