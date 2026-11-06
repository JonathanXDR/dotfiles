#!/bin/bash
# The SonarQube Read and prompt hooks never see written content. Fails open,
# like the sonar-installed wrappers.

command -v sonar >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

file=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -f "$file" ] || exit 0

output=$(sonar analyze secrets "$file" 2>&1)
status=$?
# sonar exits 51 when it finds secrets
[ "$status" -eq 51 ] || exit 0

cat >&2 <<REASON
Secret detected in the file you just wrote. Remove or replace it with a
placeholder or an environment lookup before continuing.

$output
REASON
exit 2
