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
# Output: JSONL, one object per line, sorted by project_path:
#   {"project_path","project_name","skill_name","skill_path"}
# If no projects are found, prints an informational line to stderr and exits 0 with
# no stdout. Invalid tag -> usage to stderr, exit 2.

set -euo pipefail

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
    find "$root" -maxdepth 6 \
      \( -name node_modules -o -name .git -o -name vendor \) -prune -o \
      -type f -name SKILL.md -path "*/skills/${skill_name}/SKILL.md" -print 2>/dev/null
  )
done < <(bash "${SCRIPT_DIR}/maintenance-config.sh" roots 2>/dev/null || true)

# Dedupe by project_path (keep first skill_path seen), apply blocklist, sort, emit JSONL.
emitted=0
output="$(
  sort -u "$results_file" | awk -F'\t' '!seen[$1]++' | sort -t$'\t' -k1,1 | \
  while IFS=$'\t' read -r project skill_md; do
    [ -n "$project" ] || continue
    if is_blocked "$project"; then
      continue
    fi
    name="$(basename "$project")"
    jq -nc \
      --arg pp "$project" \
      --arg pn "$name" \
      --arg sn "$skill_name" \
      --arg sp "$skill_md" \
      '{project_path: $pp, project_name: $pn, skill_name: $sn, skill_path: $sp}'
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
