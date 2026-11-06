#!/bin/bash
# Claude Code reads, changes and rewrites a file with no lock of its own, so
# sessions sharing a memory directory silently lose updates. Edit reads the file
# inside this lock, so two edits both land. Claude Code refuses a Write only if
# the session read the file and it changed since, so a Write with no earlier
# Read would discard the file. Bash writes to memory never get here.

payload=$(cat)

# Without accounts Claude Code keeps its own behavior
[ -d "$HOME/.claude-accounts" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

fields=$(printf '%s' "$payload" |
  jq -r '[.hook_event_name, .tool_name, .tool_use_id, .tool_input.file_path // ""] | @tsv' 2>/dev/null) || exit 0
IFS=$'\t' read -r event tool id path <<<"$fields"

case "$path" in
  "$HOME"/.claude/projects/*/memory/* | "$HOME"/.claude/memory/* | "$HOME"/.claude-accounts/*/memory/* | \
    "$HOME"/.claude-accounts/*/agent-memory/* | */.claude/agent-memory/* | */.claude/agent-memory-local/*) ;;
  *) exit 0 ;;
esac

store=${path%/*}
mkdir -p "$store" 2>/dev/null
[ -w "$store" ] || exit 0
lock=$store/.write-lock
owner="$id $PPID"

if [ "$event" != PreToolUse ]; then
  [ "$(readlink "$lock" 2>/dev/null)" = "$owner" ] && rm -f "$lock"
  exit 0
fi

# The lock is a symlink, because creating one is atomic and stores its owner. A
# hook denying this call fires no PostToolUse, so a waiter takes over a lock
# unchanged for 5 seconds. Past 20 seconds this refuses the call, because a
# retry costs less than a lost memory.
#
# Takeovers go one at a time, or a second waiter could delete the lock the first
# just took.
seen=''
since=$SECONDS
until ln -s "$owner" "$lock" 2>/dev/null; do
  holder=$(readlink "$lock" 2>/dev/null)
  if [ -n "$holder" ]; then
    if [ "$holder" != "$seen" ]; then
      seen=$holder
      since=$SECONDS
    fi
    if ! kill -0 "${holder##* }" 2>/dev/null || [ $((SECONDS - since)) -ge 5 ]; then
      if ln -s "$owner" "$lock.takeover" 2>/dev/null; then
        [ "$(readlink "$lock" 2>/dev/null)" = "$holder" ] && rm -f "$lock"
        rm -f "$lock.takeover"
      fi
    fi
  fi
  if [ "$SECONDS" -ge 20 ]; then
    rm -f "$lock.takeover"
    echo "Another session is writing to $store. Try this write again." >&2
    exit 2
  fi
  sleep 0.02
done

if [ "$tool" = Write ] && [ -s "$path" ]; then
  rm -f "$lock"
  echo "$path already exists, and a whole-file Write could discard what another session saved there. Change it with Edit instead." >&2
  exit 2
fi
exit 0
