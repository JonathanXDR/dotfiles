#!/bin/bash
# PreToolUse, PostToolUse and PostToolUseFailure guard: keeps memory writes from
# concurrent sessions from overwriting each other. Accounts share one memory directory
# per project, and Claude Code reads, changes and rewrites a file with no lock of its
# own. Four sessions editing MEMORY.md at once silently lost 42 of 157 edits on 2.1.318,
# each reported as a success.
#
# The lock is held from PreToolUse to PostToolUse, so one session's read and write cannot
# overlap another's. Edit reads the file inside that window, so two edits both land. It
# only covers Claude Code's file tools: a Bash command writing to memory never gets here.
#
# Write replaces the whole file, and Claude Code refuses it only when the session read
# the file earlier and it changed since. A Write with no earlier Read goes through and
# discards everything in the file, which is how two sessions picking one filename lose
# a memory, so it is refused here and Edit does the job.

payload=$(cat)

# Accounts are optional, and without them Claude Code behaves as it always did. Without
# jq nothing can read the tool call, and failing open only costs the protection.
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

# Accounts reach the store through a linked directory, so every spelling of a file finds
# the same lock.
store=${path%/*}
mkdir -p "$store" 2>/dev/null
[ -w "$store" ] || exit 0
lock=$store/.write-lock
owner="$id $PPID"

if [ "$event" != PreToolUse ]; then
  [ "$(readlink "$lock" 2>/dev/null)" = "$owner" ] && rm -f "$lock"
  exit 0
fi

# The lock is a symlink because creating one is atomic and carries its owner, so no reader
# can find a lock without one. A hook denying this call fires no PostToolUse, which leaves
# the lock behind while the session lives, so a waiter takes over one that sits unchanged
# for 5 seconds. A write takes milliseconds. Past 20 seconds of real contention the call
# is refused rather than let through, because a retry costs less than a lost memory.
#
# Takeovers go one at a time. Two waiters that both saw the same stale lock could
# otherwise each remove it, and the second would delete the lock the first just took.
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
