#!/bin/bash
# The "if" filter in settings.json is only a fast path. Claude Code spawns the
# hook conservatively for commands its rule parser cannot decompose, so this
# script decides for itself.

payload=$(cat)

# jq keeps free text such as the description from triggering or bypassing the
# guard. The raw payload can only over-block, because the override must be the
# command's first word, while an empty command would allow every push.
if command -v jq >/dev/null 2>&1; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty') || cmd=$payload
else
  cmd=$payload
fi

# Splice continuations so one inside a word cannot split the subcommand. In awk,
# because a bash substitution is super-quadratic in 3.2, and a long command
# would time out and fail open. LC_ALL=C, because awk aborts on invalid UTF-8,
# and the guarded assignment keeps the command.
spliced=$(printf '%s\n' "$cmd" | LC_ALL=C awk '
  { if (pend != "") { $0 = pend $0; pend = "" }
    if ($0 ~ /\\$/) { pend = substr($0, 1, length($0) - 1); next }
    print }
  END { if (pend != "") print pend }') && cmd=$spliced

# $scan empties quoted spans, so a quoted flag argument (git -C "My Project"
# push) cannot hide the push, while quoted mentions still over-block by design.
scan=$(printf '%s\n' "$cmd" | sed -E "s/(\"[^\"]*\"|'[^']*')//g")
# $bare deletes the quoting characters, because emptying a span hides git pu"s"h
bare=$(printf '%s\n' "$cmd" | tr -d "\"'\\\\")
if ! printf '%s\n%s\n%s\n' "$cmd" "$scan" "$bare" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]+-([^[:space:]]|\\ )+([[:space:]]+(\\ |[^-[:space:]])([^[:space:]]|\\ )*)?)*[[:space:]]+(subtree[[:space:]]+)?push([^[:alnum:]_-]|$)'; then
  exit 0
fi

# Only the first line counts, so a token on a later line cannot disable the
# guard
if printf '%s\n' "$cmd" | head -1 | grep -Eq '^[[:space:]]*(env[[:space:]]+)?CLAUDE_PUSH_OK=1([[:space:]]|$)'; then
  exit 0
fi

cat >&2 <<'REASON'
Push blocked: pushing requires an explicit user request in the current conversation.
If the user explicitly asked for this push, re-run the exact same command with
CLAUDE_PUSH_OK=1 as its first word to confirm. The guard matches text mentions of
git push too, so if this command does not actually push, the same override applies.
Otherwise report that the commits exist locally and let the user decide when to push.
REASON
exit 2
