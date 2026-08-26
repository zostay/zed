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
# A project may additionally ship sibling `maintenance-<tag>-<something>` skills.
# One of those is discovered — as an *interactive* task rather than an automated
# job — only when its front matter declares `interactive: true`. That is how a
# project splits work that needs a human out of work that does not: marking the
# whole skill interactive would strand its entire Dependabot sweep behind, say, a
# photo picker. A `maintenance-<tag>-*` skill without the flag is a helper the
# main skill invokes and stays invisible here, exactly as before. A project may
# also ship an interactive sub-skill with no `maintenance-<tag>` skill at all.
#
# `maintenance-<tag>2` is a different tag, not a sub-skill of <tag>; only an exact
# match or a hyphen-separated suffix counts.
#
# The project root is the directory containing that path (the suffix is stripped).
# Blocklist entries (from maintenance-config.sh blocklist) cause a discovered project
# to be skipped if its absolute path equals an entry, is inside a blocklisted dir, or
# its basename matches an entry.
#
# Results are also deduped by git `origin` remote: when two local checkouts map to
# the same remote, only one is emitted and a warning is printed to stderr for the
# other, so the sweep does not run two redundant, racing passes against the same
# GitHub repo. The winner is decided per *project*, ranked by what the checkout can
# contribute — one supplying an automated job beats one that does not, then lowest
# priority, then path — so a secondary checkout offering only an interactive
# sub-skill can never displace the checkout that carries the sweep. Projects with
# no remote are unaffected.
#
# Each discovered skill may declare an integer `priority:` in its YAML front
# matter to control execution order: lower runs earlier, higher runs later, and
# the default (no field, or an unparseable value) is 0. Ties break by
# project_path so the order stays deterministic. Example uses: a project that
# needs up-front user interaction sets a negative priority to run first; one that
# redeploys centrally-shared apps sets a positive priority to run last.
#
# Output: JSONL, one object per line, sorted by (priority asc, project_path, kind).
# `kind` is the last key, so a project's automated line precedes its interactive
# ones only at equal priority; a sub-skill declaring a lower priority sorts ahead
# of its own project's automated line:
#   {"project_path","project_name","skill_name","skill_path","kind","title","priority"}
# `kind` is "automated" (register it as a job) or "interactive" (register it as an
# interactive task). `title` is the skill's `description:`, used as the label
# beside the task's Start button in the observability app.
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

# Read a scalar key from a SKILL.md's YAML front matter. Scans only the leading
# `---`…`---` block, takes the first occurrence of the key, and strips
# surrounding single/double quotes and whitespace. Echoes nothing when the key is
# absent or the file has no front matter.
#
# Deliberately does NOT strip trailing `# comments`: a `description:` is prose
# that may legitimately contain a `#`. The one key that wants comment-stripping
# is `priority:`, which does it itself below.
read_fm_raw() {
  local skill_md="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0 ~ /^---[[:space:]]*$/ { infm=1; next }
    infm && $0 ~ /^---[[:space:]]*$/ { exit }
    infm {
      pat = "^[[:space:]]*" key "[[:space:]]*:"
      if ($0 ~ pat) {
        sub(pat "[[:space:]]*", "")
        sub(/[[:space:]]+$/, "")
        print
        exit
      }
    }
  ' "$skill_md" 2>/dev/null
}

# As above, then strip one matching pair of surrounding quotes.
#
# The trim has to happen on both sides of the unquoting, which is the whole
# reason this is not one pass: trimming only first leaves `"true" ` as `true"`
# (a trailing space defeats the closing-quote match, so the value silently stops
# meaning what it says), and trimming only afterwards leaves `" -100 "` as
# ` -100 `. Neither is hypothetical — the first silently dropped an interactive
# skill from discovery and the second broke a documented `priority` form.
#
# Deliberately does NOT strip trailing `# comments`: a `description:` is prose
# that may contain a `#`. The one key that wants comment-stripping is
# `priority:`, which does it itself below — and must, because the comment sits
# *outside* the closing quote, where unquoting cannot see it.
read_fm_scalar() {
  local val
  val="$(read_fm_raw "$1" "$2")"
  val="${val#"${val%%[![:space:]]*}"}"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# Read the integer `priority:` from a SKILL.md's YAML front matter, strip a
# trailing comment, and validate it as an optionally-signed integer. So
# `priority: '-100'`, `priority: " -100 "`, and `priority: -100  # runs first`
# all parse to -100. Anything missing or unparseable yields the default of 0.
read_priority() {
  local skill_md="$1" val
  # Read raw and strip the comment *before* touching quotes: in
  # `priority: '-100'  # runs first` the comment follows the closing quote, so
  # any unquoting done first sees an unterminated value and gives up. An integer
  # cannot legitimately contain a quote or a space, so both are simply removed
  # wherever they appear — the same thing the pre-0.13.0 parser did.
  val="$(read_fm_raw "$skill_md" priority)"
  val="${val%%#*}"
  val="${val//\"/}"
  val="${val//\'/}"
  val="${val//[[:space:]]/}"
  if printf '%s' "$val" | grep -Eq '^-?[0-9]+$'; then
    printf '%s' "$val"
  else
    printf '0'
  fi
}

# Return 0 when a SKILL.md declares `interactive: true` in its front matter —
# i.e. it is work that needs a human and belongs in the interactive queue rather
# than the automated one. Accepts true/yes/1 in any case; anything else, and any
# absent key, means automated.
read_interactive() {
  local val
  val="$(read_fm_scalar "$1" interactive)"
  val="${val%%#*}"
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "$val" in
    true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

# One-line label for an interactive task, shown to the human in the app's
# interactive bar next to its Start button. The skill's own `description:` is the
# best available prose; fall back to the skill name so the row is never blank.
read_title() {
  local skill_md="$1" fallback="$2" val
  val="$(read_fm_scalar "$skill_md" description)"
  if [ -n "$val" ]; then printf '%s' "$val"; else printf '%s' "$fallback"; fi
}

# Normalize a project's `origin` git remote URL to a canonical
# "host/owner/repo" key, so two local checkouts of the *same* GitHub repo
# collapse to one regardless of remote form — SSH (`git@github.com:o/r.git`),
# `ssh://git@github.com/o/r`, or `https://github.com/o/r`. Lowercases and strips
# the scheme, any credentials, a trailing `.git`, and a trailing slash. Echoes
# nothing when the path has no git remote (or git is unavailable), so such
# projects never dedupe against each other.
normalize_remote() {
  local path="$1" url
  url="$(git -C "$path" remote get-url origin 2>/dev/null || true)"
  [ -n "$url" ] || return 0
  url="${url%.git}"
  url="${url%/}"
  case "$url" in
    *://*) url="${url#*://}"; url="${url#*@}" ;;                  # https:// or ssh:// (drop scheme + user@)
    *@*:*) url="${url#*@}";   url="${url%%:*}/${url#*:}" ;;       # git@host:owner/repo -> host/owner/repo
  esac
  printf '%s' "$url" | tr '[:upper:]' '[:lower:]'
}

# Collect discovered project paths keyed to their skill path.
# We store "project_path<TAB>skill_path" lines, then dedupe by project_path.
results_file="$(mktemp)"
# Tracks "<normalized_remote><TAB><project_path>" for the first checkout seen of
# each remote, so later checkouts of the same remote can be deduped (Problem 5).
seen_remotes="$(mktemp)"
# Skills that survived the blocklist, one line each, in emission order.
ranked_file="$(mktemp)"
# Projects that lost a git-remote contest, one path per line.
blocked_remote="$(mktemp)"
trap 'rm -f "$results_file" "$seen_remotes" "$ranked_file" "$blocked_remote"' EXIT

# For each configured root, search for matching SKILL.md files in both layouts.
while IFS= read -r root; do
  [ -z "$root" ] && continue
  [ -d "$root" ] || continue

  # Find SKILL.md files at the expected relative locations, pruning heavy dirs.
  # The glob is a prefix match so sibling sub-skills (`maintenance-<tag>-*`) are
  # seen too; the case below decides which of them actually count.
  while IFS= read -r skill_md; do
    [ -z "$skill_md" ] && continue
    project=""
    found=""
    # The matched directory name — which is NOT necessarily $skill_name now that
    # sub-skills are in scope. Strip the project root using the name that is
    # actually there, or a sub-skill's project would be mis-derived.
    found="$(basename "$(dirname "$skill_md")")"
    case "$found" in
      "$skill_name"|"$skill_name"-*) ;;
      # A prefix match that is not the skill or a hyphen-separated sub-skill of
      # it: `maintenance-weekly2` is a different tag, not part of `weekly`.
      *) continue ;;
    esac
    case "$skill_md" in
      */.claude/skills/"$found"/SKILL.md)
        project="${skill_md%/.claude/skills/$found/SKILL.md}"
        ;;
      */skills/"$found"/SKILL.md)
        project="${skill_md%/skills/$found/SKILL.md}"
        ;;
      *)
        continue
        ;;
    esac
    [ -n "$project" ] || continue

    # The tag skill itself is the project's automated job. A sub-skill counts
    # only when it explicitly declares `interactive: true` — an undeclared
    # `maintenance-<tag>-*` skill is a helper the main skill invokes, and stays
    # invisible to discovery exactly as it was before this existed.
    if [ "$found" = "$skill_name" ]; then
      kind="automated"
    elif read_interactive "$skill_md"; then
      kind="interactive"
    else
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$project" "$skill_md" "$found" "$kind" >>"$results_file"
  done < <(
    find "$root" -maxdepth 12 \
      \( -name node_modules -o -name .git -o -name vendor \) -prune -o \
      -type f -name SKILL.md -path "*/skills/${skill_name}*/SKILL.md" -print 2>/dev/null
  )
done < <(bash "${SCRIPT_DIR}/maintenance-config.sh" roots 2>/dev/null || true)

# Dedupe by (project_path, skill_name) — a project now contributes one line per
# participating skill, not one line total — apply the blocklist, read each
# skill's priority, and sort by (priority asc, project_path, kind). The
# intermediate line is
# "priority<TAB>project_path<TAB>kind<TAB>skill_path<TAB>skill_name"; `sort
# -k1,1n` orders numerically by priority, `-k2,2` breaks ties by path
# deterministically, and `-k3,3` puts a project's `automated` line ahead of its
# `interactive` ones at equal priority ('a' sorts before 'i').
sort -u "$results_file" | awk -F'\t' '!seen[$1 "\t" $3]++' | \
while IFS=$'\t' read -r project skill_md found kind; do
  [ -n "$project" ] || continue
  if is_blocked "$project"; then
    continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(read_priority "$skill_md")" "$project" "$kind" "$skill_md" "$found"
done | sort -t$'\t' -k1,1n -k2,2 -k3,3 >"$ranked_file"

# Dedupe by git remote, at *project* granularity and before anything is emitted.
#
# Two local checkouts of one GitHub repo must not both sweep it — that is a
# redundant, racing pass against the same remote. Deciding this per skill line
# would be wrong in two ways: a project would contest its own claim (its
# automated skill taking the remote, then its interactive tasks being dropped as
# duplicates of it), and the winner would be whichever *line* sorted first, so a
# secondary checkout offering nothing but a low-priority interactive sub-skill
# could beat the checkout that actually carries the automated job.
#
# The contest is therefore ranked by what a checkout can contribute: one that
# supplies an automated job wins over one that does not, then lowest priority,
# then path. Projects with no remote never contest. One decision, one warning,
# per project.
while IFS= read -r project; do
  [ -n "$project" ] || continue
  remote="$(normalize_remote "$project")"
  [ -n "$remote" ] || continue
  prior="$(awk -F'\t' -v r="$remote" '$1==r{print $2; exit}' "$seen_remotes")"
  if [ -n "$prior" ]; then
    printf 'Warning: %s shares git remote (%s) with already-selected %s; skipping duplicate checkout.\n' \
      "$project" "$remote" "$prior" >&2
    printf '%s\n' "$project" >>"$blocked_remote"
  else
    printf '%s\t%s\n' "$remote" "$project" >>"$seen_remotes"
  fi
done < <(
  awk -F'\t' '
    { if (!($2 in minp) || $1+0 < minp[$2]) minp[$2] = $1+0
      if ($3 == "automated") auto[$2] = 1
      seen[$2] = 1 }
    END { for (pp in seen) printf "%d\t%d\t%s\n", (auto[pp] ? 0 : 1), minp[pp], pp }
  ' "$ranked_file" | sort -t$'\t' -k1,1n -k2,2n -k3,3 | cut -f3-
)

emitted=0
output="$(
  while IFS=$'\t' read -r priority project kind skill_md found; do
    [ -n "$project" ] || continue
    if [ -s "$blocked_remote" ] && grep -Fxq "$project" "$blocked_remote"; then
      continue
    fi
    name="$(basename "$project")"
    jq -nc \
      --arg pp "$project" \
      --arg pn "$name" \
      --arg sn "$found" \
      --arg sp "$skill_md" \
      --arg kd "$kind" \
      --arg ti "$(read_title "$skill_md" "$found")" \
      --arg pr "$priority" \
      '{project_path: $pp, project_name: $pn, skill_name: $sn, skill_path: $sp,
        kind: $kd, title: $ti, priority: ($pr|tonumber)}'
  done < "$ranked_file"
)"

if [ -n "$output" ]; then
  printf '%s\n' "$output"
  emitted=1
fi

if [ "$emitted" -eq 0 ]; then
  echo "No projects defining '${skill_name}' found under the configured search roots." >&2
  exit 0
fi
