#!/bin/bash
# SessionStart, UserPromptSubmit and SessionEnd guard: keeps two processes off one
# conversation. Accounts share their transcripts, so any of them can reopen a session
# another one is running. Claude Code does not stop that: both append to one transcript
# and fork it, and the next resume follows only the newest branch, so the other branch
# looks lost even though it is still on disk.
#
# claude:as and plain claude avoid this at launch with --fork-session, by asking this
# script through `live`. That leaves /resume inside a running session, which no launcher
# sees. SessionStart cannot refuse it (continue:false is ignored there), so it warns and
# the first prompt is blocked. A blocked prompt still writes one line to the transcript,
# and that line can hide newer turns until the owner writes again, so blocking is the
# fallback and forking the rule.
#
# Each session records its owner in ~/.claude/session-owners/<session id>: the pid, its
# start time, the account and the directory. The start time tells a live owner from a
# pid the system reused after a crash.
#
# Usage: guard-live-sessions.sh live <directory> [session id...]
#        Prints the owner and succeeds if another process holds one of those sessions,
#        or with none named, if another process runs in that directory.

owners=$HOME/.claude/session-owners

# Accounts are optional, and without them Claude Code behaves as it always did. A hook
# has to exit 0 here, or Claude Code would report an error on every event.
if [ ! -d "$HOME/.claude-accounts" ]; then
  [ "${1:-}" = live ] && exit 1
  exit 0
fi

read_owner() {
  { read -r pid && read -r start && read -r account && read -r directory; } <"$1"
} 2>/dev/null

# read drops the padding ps puts around the time, as it does for the recorded one.
started() {
  read -r time <<<"$(ps -o lstart= -p "$1" 2>/dev/null)"
  printf '%s' "$time"
}

# ps can come back empty in a sandbox. kill -0 still rules out a dead owner then.
owner_alive() {
  kill -0 "$pid" 2>/dev/null || return 1
  current=$(started "$pid")
  [ -z "$current" ] || [ "$current" = "$start" ]
}

if [ "${1:-}" = live ]; then
  shift
  where=$1
  shift
  for file in "$owners"/*; do
    read_owner "$file" || continue
    [ "$pid" != "$PPID" ] && owner_alive || continue
    match=''
    [ $# -eq 0 ] && [ "$directory" = "$where" ] && match=1
    for session in "$@"; do
      [ "$session" = "${file##*/}" ] && match=1
    done
    if [ -n "$match" ]; then
      echo "process $pid ($account)"
      exit 0
    fi
  done
  exit 1
fi

payload=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
fields=$(printf '%s' "$payload" | jq -r '[.hook_event_name, .session_id, .cwd] | @tsv' 2>/dev/null) || exit 0
IFS=$'\t' read -r event id cwd <<<"$fields"
[ -n "$id" ] || exit 0
mkdir -p "$owners" || exit 0
file=$owners/$id

if [ "$event" = SessionEnd ]; then
  read_owner "$file" && [ "$pid" = "$PPID" ] && rm -f "$file"
  exit 0
fi

if read_owner "$file" && [ "$pid" != "$PPID" ] && owner_alive; then
  message="This conversation is live in process $pid ($account). Two sessions would fork its transcript and hide each other's work on the next resume. Close that session, or run /branch to continue in a copy."
  if [ "$event" = UserPromptSubmit ]; then
    jq -n --arg reason "$message" \
      '{decision: "block", reason: $reason, hookSpecificOutput: {hookEventName: "UserPromptSubmit", suppressOriginalPrompt: true}}'
  else
    jq -n --arg message "$message" '{systemMessage: $message}'
  fi
  exit 0
fi

# A rename, so that a reader never sees half a record.
if ! read_owner "$file" || [ "$pid" != "$PPID" ]; then
  name=${CLAUDE_CONFIG_DIR##*/}
  printf '%s\n' "$PPID" "$(started "$PPID")" "${name:-primary}" "$cwd" >"$file.$$"
  mv -f "$file.$$" "$file"
fi

[ "$event" = SessionStart ] || exit 0

# Worktrees are the supported way to edit in parallel, so say so while it is still cheap.
# The same pass drops the records crashed sessions left behind.
neighbours=''
for other in "$owners"/*; do
  [ "$other" = "$file" ] && continue
  read_owner "$other" || continue
  [ "$pid" = "$PPID" ] && continue
  if ! owner_alive; then
    rm -f "$other"
  elif [ "$directory" = "$cwd" ]; then
    neighbours="$neighbours, process $pid ($account)"
  fi
done
warning=''
[ -n "$neighbours" ] &&
  warning="Other sessions are working in this directory: ${neighbours#, }. Edits to the same files can conflict, so use --worktree for parallel work."

# Transcripts do not record the account, but this context stays in them, so a conversation
# that moved between accounts still shows which ones worked on it.
context=''
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && context="This session runs as the Claude Code account ${CLAUDE_CONFIG_DIR##*/}."

[ -n "$warning$context" ] || exit 0
jq -n --arg warning "$warning" --arg context "$context" '
  (if $warning == "" then {} else {systemMessage: $warning} end)
  + (if $context == "" then {} else {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}} end)'
