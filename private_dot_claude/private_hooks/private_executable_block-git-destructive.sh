#!/bin/bash
# CLAUDE_DESTRUCTIVE_OK=1 as the command's first word confirms an explicit user
# request

payload=$(cat)

# A jq failure falls back to the raw payload, because an empty command would
# allow everything. JSON punctuation becomes line breaks, or the stripper below
# would empty a payload that is nothing but quoted spans. The raw payload misses
# a command with JSON escapes left in it.
json_view() { printf '%s' "$payload" | tr '"{},' '\n\n\n\n'; }
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty') || cmd=$(json_view)
else
  cmd=$(json_view)
fi

# Splice continuations so one inside a word cannot split the subcommand. In awk,
# because a bash substitution is super-quadratic in 3.2, and a long command
# would time out and fail open.
cmd=$(printf '%s\n' "$cmd" | awk '
  { if (pend != "") { $0 = pend $0; pend = "" }
    if ($0 ~ /\\$/) { pend = substr($0, 1, length($0) - 1); next }
    print }
  END { if (pend != "") print pend }')

# Matching runs on a copy with heredoc bodies dropped and quoted spans emptied,
# so documentation text cannot trip the guard. A flag hidden inside quotes or a
# command a heredoc feeds to an interpreter is missed, which is deliberate
# bypass and out of scope for a best-effort guard.
scan=$(printf '%s\n' "$cmd" | awk '
  # Arithmetic $(( )) spans are consumed whole so their shifts never look like
  # markers. If the terminator never appears the parse was wrong, so held lines
  # are re-emitted and a live command is never dropped.
  function stripline(s,   out, i, c, c2, q, t, n) {
    out = ""; q = ""; n = length(s); i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (q != "") { if (c == q) q = ""; i++; continue }
      if (c == "\"" || c == "\047") { q = c; i++; continue }
      if (c == "$" && substr(s, i + 1, 2) == "((") {
        i += 3
        while (i <= n && substr(s, i, 2) != "))") i++
        if (i <= n) i += 2
        continue
      }
      if (c == "<" && substr(s, i + 1, 1) == "<") {
        if (substr(s, i + 2, 1) == "<") { i += 3; continue }
        out = out "<<"; i += 2
        if (substr(s, i, 1) == "-") { out = out "-"; i++ }
        while (substr(s, i, 1) == " " || substr(s, i, 1) == "\t") i++
        t = ""; c2 = substr(s, i, 1)
        if (c2 == "\"" || c2 == "\047") { t = c2; i++ }
        while (i <= n && substr(s, i, 1) ~ /[A-Za-z0-9_-]/) { out = out substr(s, i, 1); i++ }
        if (t != "" && substr(s, i, 1) == t) i++
        continue
      }
      out = out c; i++
    }
    return out
  }
  skip != "" {
    line = $0
    if (dash) sub(/^\t+/, "", line)
    if (line == skip) { skip = ""; h = 0 } else { held[++h] = $0 }
    next
  }
  {
    stripped = stripline($0)
    if (match(stripped, /<<-?[A-Za-z_][A-Za-z0-9_-]*/) &&
        (RSTART == 1 || substr(stripped, RSTART - 1, 1) ~ /[[:space:]]/)) {
      tag = substr(stripped, RSTART, RLENGTH)
      dash = (tag ~ /^<<-/) ? 1 : 0
      sub(/^<<-?/, "", tag)
      skip = tag
    }
    print stripped
  }
  END { if (skip != "") for (j = 1; j <= h; j++) print stripline(held[j]) }')

# Backslash-escaped spaces stay inside a token, so "git -C My\ Project reset" is
# one prefix
gitpre='(^|[^[:alnum:]_./-])git([[:space:]]+-([^[:space:]]|\\ )+([[:space:]]+(\\ |[^-[:space:]])([^[:space:]]|\\ )*)?)*[[:space:]]+'

end='([[:space:];&|<>)`]|$)'

# pathview removes redirects, so a redirect target is never read as a pathspec.
# flagview truncates at " -- ", so a file named -f is never read as a flag.
pathview=$(printf '%s\n' "$scan" | sed -E 's/[0-9]*[<>]{1,3}[[:space:]]*(&[0-9]*|[^[:space:];&|)]*)//g')
flagview=$(printf '%s\n' "$scan" | sed -E 's/ -- [^;&|)]*//g')

reason=""
if printf '%s\n' "$flagview" | grep -Eq "${gitpre}reset[^;&|]*--hard${end}"; then
  reason="git reset --hard discards uncommitted changes"
# git refuses -x, -X and -d without -f
elif printf '%s\n' "$flagview" | grep -Eq "${gitpre}clean[^;&|]*([[:space:]]-[a-zA-Z]*f[a-zA-Z]*|--force)${end}"; then
  reason="forced git clean deletes untracked files"
elif printf '%s\n' "$flagview" | grep -Eq "${gitpre}checkout[^;&|]*([[:space:]]-[a-zA-Z]*f[a-zA-Z]*|--force)${end}"; then
  reason="forced git checkout discards uncommitted changes"
# --force-create (-C) only forces the branch creation, so --force has to end the
# token
elif printf '%s\n' "$flagview" | grep -Eq "${gitpre}switch[^;&|]*([[:space:]]-[a-zA-Z]*f[a-zA-Z]*|--force|--discard-changes)${end}"; then
  reason="forced git switch discards uncommitted changes"
elif printf '%s\n' "$pathview" | grep -Eq "${gitpre}checkout[^;&|]*[[:space:]]--([[:space:]]|$)" ||
     printf '%s\n' "$pathview" | grep -Eq "${gitpre}checkout[^;&|]*[[:space:]]\.\.?(/[^[:space:];&|)]*)?${end}"; then
  reason="git checkout with a pathspec overwrites uncommitted changes"
elif printf '%s\n' "$scan" | grep -Eq "${gitpre}restore([^;&|]|$)"; then
  # Check each segment, so --staged on one restore cannot exempt a plain restore
  # elsewhere
  while IFS= read -r seg; do
    printf '%s\n' "$seg" | grep -Eq "${gitpre}restore${end}" || continue
    segflags=${seg%% -- *}
    printf '%s\n' "$segflags" | grep -Eq -- '--help([[:space:]]|$)|[[:space:]]-h([[:space:]]|$)' && continue
    if ! printf '%s\n' "$segflags" | grep -Eq "${gitpre}restore[^;&|]*(--staged|[[:space:]]-[A-Za-z]*S[A-Za-z]*)${end}" ||
       printf '%s\n' "$segflags" | grep -Eq "${gitpre}restore[^;&|]*(--worktree|[[:space:]]-[A-Za-z]*W[A-Za-z]*)${end}"; then
      reason="git restore overwrites uncommitted changes in the worktree"
    fi
  done <<<"$(printf '%s\n' "$scan" | tr ';&|' '\n')"
fi

[ -z "$reason" ] && exit 0

# Only the first line counts, so a token on a later line cannot disable the
# guard
if printf '%s\n' "$cmd" | head -1 | grep -Eq '^[[:space:]]*(env[[:space:]]+)?CLAUDE_DESTRUCTIVE_OK=1([[:space:]]|$)'; then
  exit 0
fi

cat >&2 <<REASON
Destructive git command blocked: $reason.
If the user explicitly asked for this, re-run the exact same command with
CLAUDE_DESTRUCTIVE_OK=1 as its first word to confirm. Otherwise choose a
non-destructive alternative (git stash, git restore --staged, a new branch)
or ask the user first.
REASON
exit 2
