#!/bin/bash
# A bare tool name in a project's permissions.deny withdraws the tool from the
# session schema, which otherwise reads as a Claude Code fault

payload=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

# Claude Code does not walk up to the repository root, so a subdirectory session
# loads no project settings, and the notice must not fire there
project=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$project" ] || project=${CLAUDE_PROJECT_DIR:-$PWD}

findings=""
for name in settings.json settings.local.json; do
  file=$project/.claude/$name
  [ -f "$file" ] || continue

  denied=$(jq -r '
    [ .permissions.deny // [] | .[]
      | select(test("^(Bash|Read|Edit|Write|NotebookEdit|Glob|Grep|Task|Agent|WebFetch|WebSearch)$")) ]
    | join(", ")' "$file" 2>/dev/null)

  [ -n "$denied" ] && findings="$findings$file denies: $denied"$'\n'
done

[ -n "$findings" ] || exit 0

jq -n --arg f "$findings" '
  "Project settings removed core tools from this session.\n" + $f +
  "No allow rule or permission mode restores them. Starting the session from a subdirectory opts out, since project settings load from the working directory."
  | {
      systemMessage: .,
      hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: . }
    }'
