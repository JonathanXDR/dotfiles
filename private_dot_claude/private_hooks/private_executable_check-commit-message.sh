#!/bin/bash
# Bodies and footers stay unrestricted so repository conventions keep working.
# Fails open when the message cannot be extracted, such as with editor-based
# commits or exotic quoting.

payload=$(cat)

if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
else
  exit 0
fi

# Splice continuations so one inside a word cannot split the subcommand. In awk,
# because a bash substitution is super-quadratic in 3.2, and a long command
# would time out and fail open.
cmd=$(printf '%s\n' "$cmd" | awk '
  { if (pend != "") { $0 = pend $0; pend = "" }
    if ($0 ~ /\\$/) { pend = substr($0, 1, length($0) - 1); next }
    print }
  END { if (pend != "") print pend }')

# The command's structure, not message text, decides whether this is a commit.
# Arithmetic $(( )) spans are consumed whole so their shifts never look like
# markers. If the terminator never appears the parse was wrong, so the held
# lines are re-emitted and a live command is never dropped. With raw=1 surviving
# lines keep their quotes.
stripper='
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
    print (raw ? $0 : stripped)
  }
  END { if (skip != "") for (j = 1; j <= h; j++) print (raw ? held[j] : stripline(held[j])) }'
scan=$(printf '%s\n' "$cmd" | awk "$stripper")

# Backslash-escaped spaces stay inside a token, so "git -C My\ Repo commit" is
# one prefix
gitpre='(^|[^[:alnum:]_./-])git([[:space:]]+-([^[:space:]]|\\ )+([[:space:]]+(\\ |[^-[:space:]])([^[:space:]]|\\ )*)?)*[[:space:]]+'
printf '%s\n' "$scan" | grep -Eq "${gitpre}commit([^[:alnum:]_-]|$)" || exit 0

# Only the first line counts, so a token on a later line cannot disable the
# guard
if printf '%s\n' "$cmd" | head -1 | grep -Eq '^[[:space:]]*(env[[:space:]]+)?CLAUDE_COMMIT_OK=1([[:space:]]|$)'; then
  exit 0
fi

block() {
  cat >&2 <<REASON
Commit blocked: $1
Fix the message and re-run. If this repository's documented commit convention
intentionally differs, re-run the exact same command with CLAUDE_COMMIT_OK=1
as its first word to confirm.
REASON
  exit 2
}

# One commit invocation per line, quote-aware so a ; & or | in message text does
# not truncate a segment. Falls back to the whole command when quoting defeats
# the match.
body=$(printf '%s\n' "$cmd" | awk -v raw=1 "$stripper")
segs=$(printf '%s\n' "$body" | grep -oE "${gitpre}commit((\"[^\"]*\")|('[^']*')|[^;&|\"'])*")
[ -n "$segs" ] || segs=$cmd

# msgline matches the pattern at the start of a message line, so prose mentions
# stay allowed. The gap admits prefixes like the robot emoji of the Claude Code
# footer. trailerflag checks $scan so a quoted mention cannot match, then $cmd
# for a value quoting may hide.
gap="[^[:alnum:]\"']*"
msgline() {
  printf '%s\n' "$segs" | grep -Eiq "([\"']|\\\\n|[[:space:]]-[a-zA-Z]*m[= ])${gap}$1" ||
    printf '%s\n' "$cmd" | grep -Eiq "^${gap}$1"
}
trailerflag() { # $1 key regex, $2 value regex
  printf '%s\n' "$scan" | grep -Eiq -- "--trailer[= ][[:space:]]*$1[[:space:]]*[:=]" &&
    printf '%s\n' "$cmd" | grep -Eiq -- "--trailer[= ][[:space:]\"']*$1[[:space:]]*[:=][\"']?$2"
}
if msgline 'Claude-Session[[:space:]]*[:=]' || trailerflag 'Claude-Session' ''; then
  block "the message contains a Claude-Session trailer."
fi
if msgline 'Co-Authored-By[[:space:]]*[:=].*claude' || trailerflag 'Co-Authored-By' '.*claude'; then
  block "the message contains a Co-Authored-By Claude trailer."
fi
if msgline 'Generated with \[Claude Code\]'; then
  block "the message contains a Generated with Claude Code line."
fi

# An empty subject means that invocation is unparseable, which fails open
sq="'"
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  marg=$(printf '%s\n' "$seg" |
    grep -oE -- "(^|[[:space:]])(-[a-zA-Z]*m|--message)[= ]*(\"[^\"\$]*\"|$sq[^$sq]*$sq|[^\"$sq[:space:]\$-]([^[:space:]]|\\\\ )*)" |
    head -1)
  subject=$(printf '%s\n' "$marg" |
    sed -E "s/^[[:space:]]*(-[a-zA-Z]*m|--message)[= ]*//; s/\\\\ / /g; s/^[\"$sq]//; s/[\"$sq]\$//")
  # Two heredocs on one line make the next line the first heredoc's body, so
  # fail open
  if [ -z "$subject" ] && ! printf '%s\n' "$scan" | grep -Eq '<<.*<<'; then
    subject=$(printf '%s\n' "$cmd" |
      sed -nE "\\#${gitpre}commit[^;&|]*<<-?[[:space:]]*[\"']?[A-Za-z_]#{n;s/^[[:space:]]*//;p;q;}")
  fi
  [ -n "$subject" ] || continue

  case "$subject" in
  Merge\ * | Revert\ * | Reapply\ * | fixup!* | squash!* | amend!*) continue ;;
  esac

  if ! printf '%s\n' "$subject" | grep -Eq '^[a-z][a-z0-9-]*(\([a-zA-Z0-9._/-]+\))?!?: [^[:space:]]'; then
    block "the subject does not follow Conventional Commits.
Expected: <type>[optional scope][!]: <description> with a lowercase type,
for example: feat(auth)!: drop v1 tokens
Got: $subject"
  fi
done <<<"$segs"

exit 0
