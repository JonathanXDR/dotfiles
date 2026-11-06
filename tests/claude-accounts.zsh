#!/bin/zsh -f
# Run with `zsh -f tests/claude-accounts.zsh`. HOME is a throwaway directory and
# stubs stand in for claude, open and trash, so nothing here can reach a real
# login, keychain item or browser.

repo="${0:A:h:h}"
tmp="$(mktemp -d)"
trap 'command rm -rf -- "$tmp"' EXIT

export HOME="${tmp}/home"
stubs="${tmp}/stubs"
calls="${tmp}/calls"
mkdir -p "$HOME/.claude/skills/synced/org_acct" "$HOME/.claude/skills/.trash" \
  "$HOME/.claude/commands" "$HOME/.claude/plugins" "$HOME/.local/bin" "$stubs" "$calls"
export PATH="${stubs}:/usr/bin:/bin:/opt/homebrew/bin"
unset CLAUDE_CONFIG_DIR CLAUDE_CODE_PLUGIN_CACHE_DIR BROWSER

print -r -- '{"hooks":{}}' > "$HOME/.claude/settings.json"
print -r -- '# shared' > "$HOME/.claude/CLAUDE.md"
mkdir -p "$HOME/.agents/skills/alpha" "$HOME/.agents/skills/beta"
ln -s "$HOME/.agents/skills/alpha" "$HOME/.claude/skills/alpha"
ln -s "$HOME/.agents/skills/beta" "$HOME/.claude/skills/beta"
print -r -- '{"mcpServers":{"one":{"command":"true"}}}' > "$HOME/.claude.json"
cp "${repo}/dot_local/bin/executable_claude-account-browser" "$HOME/.local/bin/claude-account-browser"
chmod +x "$HOME/.local/bin/claude-account-browser"

cat > "${stubs}/claude" <<'STUB'
#!/bin/zsh -f
# auth subcommands keep a marker in the config directory
out="$(mktemp "${CALLS}/call.XXXXXX")"
{
  print -r -- "argv=$*"
  print -r -- "cfg=${CLAUDE_CONFIG_DIR-<unset>}"
  print -r -- "plugins=${CLAUDE_CODE_PLUGIN_CACHE_DIR-<unset>}"
  print -r -- "browser=${BROWSER-<unset>}"
  print -r -- "profiles=${ANTHROPIC_CONFIG_DIR-<unset>}"
  env | grep -E "^(${INHERITED})=" | sed 's/^/leak=/'
} > "$out"
case "$*" in
  "auth status") [[ -f "${CLAUDE_CONFIG_DIR}/.signed-in" ]] ;;
  "auth login")
    [[ -n "${STUB_LOGIN_FAILS:-}" ]] && exit 1
    touch "${CLAUDE_CONFIG_DIR}/.signed-in"
    print -r -- "{\"oauthAccount\":{\"emailAddress\":\"${STUB_EMAIL:-a@example.com}\",\"organizationName\":\"Org\",\"accountUuid\":\"${STUB_UUID:-uuid-a}\"}}" > "${CLAUDE_CONFIG_DIR}/.claude.json"
    ;;
  "auth logout")
    [[ -n "${STUB_LOGOUT_FAILS:-}" ]] && exit 1
    command rm -f "${CLAUDE_CONFIG_DIR}/.signed-in"
    ;;
esac
STUB
cat > "${stubs}/open" <<'STUB'
#!/bin/sh
for arg in "$@"; do printf '[%s]' "$arg"; done >> "${CALLS}/open"
printf '\n' >> "${CALLS}/open"
STUB
cat > "${stubs}/trash" <<'STUB'
#!/bin/sh
printf '%s\n' "$1" >> "${CALLS}/trash"
mv "$1" "${CALLS}/trashed-${1##*/}"
STUB
mkdir -p "${tmp}/no-trash"
print -r -- '#!/bin/sh' > "${tmp}/no-trash/trash"
print -r -- 'exit 1' >> "${tmp}/no-trash/trash"
chmod +x "${stubs}/claude" "${stubs}/open" "${stubs}/trash" "${tmp}/no-trash/trash"
export CALLS="$calls"

# Everything claude:_run has to drop. Listed here rather than read from the
# function, so that a name dropped there fails a test.
inherited=(
  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_PROFILE CLAUDE_CODE_OAUTH_TOKEN
  CLAUDE_CODE_OAUTH_REFRESH_TOKEN CLAUDE_CODE_SESSION_ACCESS_TOKEN
  CLAUDE_CODE_ACCOUNT_UUID CLAUDE_SECURESTORAGE_CONFIG_DIR
  CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT
  CLAUDE_EFFORT CLAUDECODE
)
export INHERITED="${(j:|:)inherited}"

source "${repo}/dot_functions"
eval "$(grep -E '^alias claude=' "${repo}/dot_aliases")"

accounts="$HOME/.claude-accounts"
typeset -i passed=0 failed=0

check() {
  local name="$1"; shift
  if "$@"; then
    (( passed++ ))
  else
    (( failed++ ))
    print -r -- "not ok - ${name}"
  fi
}
fails() { ! "$@" &>/dev/null; }
answer() { print -r -- "$1" | "${@:2}"; }
same() { [[ "$1" == "$2" ]] || { print -r -- "  expected: $2"; print -r -- "  actual:   $1"; return 1; }; }
has() { [[ "$1" == *"$2"* ]] || { print -r -- "  missing '$2' in: $1"; return 1; }; }
hasnt() { [[ "$1" != *"$2"* ]] || { print -r -- "  unexpected '$2' in: $1"; return 1; }; }

reset_calls() { command rm -f "${calls}"/call.*(N) "${calls}/open"; }
last_call() { cat "${calls}"/call.*(om[1]); }
call_count() { local -a c=( "${calls}"/call.*(N) ); print -r -- ${#c}; }

for bad in '' '../x' 'a/b' 'Upper' '-x' '.' '..' 'a b' 'a.b'; do
  check "claude:add rejects '${bad}'" fails claude:add "$bad"
done
check "a rejected name creates nothing" test ! -e "$accounts"
# The directory has to exist, or -d rejects these paths before any name check
mkdir -p "$accounts"
check "claude:as rejects a traversal" fails claude:as ../.claude
check "claude:chrome rejects a traversal" fails claude:chrome ../.claude
check "claude:remove rejects a traversal" fails answer y claude:remove ../.claude
check "a traversal leaves the primary in place" test -f "$HOME/.claude/settings.json"
check "claude:as refuses an unknown account" fails claude:as nobody
check "a rejected name never reaches claude" same "$(call_count)" 0
check "a rejected name never reaches the Trash" test ! -e "${calls}/trash"

# The alias is loaded here, as in a real shell, and has to count for nothing.
# /usr/bin stays on PATH so that mkdir works and only the guard can stop this.
without_claude() { local PATH=/usr/bin:/bin; claude:add nope; }
check "claude:add stops when claude is not installed" fails without_claude
check "a missing claude creates no account" test ! -e "$accounts/nope"
check "claude:add needs one argument" fails claude:add
check "claude:as needs an account" fails claude:as
check "sourcing leaves the primary alone" same "${CLAUDE_CONFIG_DIR-<unset>}" "<unset>"

reset_calls
STUB_EMAIL=work@example.com STUB_UUID=uuid-work claude:add work >/dev/null
home="${accounts}/work"
check "claude:add creates the account" test -d "$home"
check "the parent is private" same "$(stat -f %Lp "$accounts")" 700
check "the account is private" same "$(stat -f %Lp "$home")" 700
check "settings.json is one hop to the shared file" same "$(readlink "$home/settings.json")" "$HOME/.claude/settings.json"
check "CLAUDE.md is linked" same "$(readlink "$home/CLAUDE.md")" "$HOME/.claude/CLAUDE.md"
check "commands is linked" same "$(readlink "$home/commands")" "$HOME/.claude/commands"
check "an absent shared entry is not linked" test ! -e "$home/agents" -a ! -L "$home/agents"
check "skills is a real directory" test -d "$home/skills" -a ! -L "$home/skills"
check "each skill is linked" same "$(readlink "$home/skills/alpha")" "$HOME/.claude/skills/alpha"
check "synced skills stay per account" test ! -e "$home/skills/synced"
check "hidden skill entries are not linked" test ! -e "$home/skills/.trash"
for entry in agent-memory file-history memory paste-cache plans projects session-env tasks teams uploads usage-data; do
  check "${entry} is shared" same "$(readlink "$home/$entry")" "$HOME/.claude/$entry"
  check "${entry} survives cleanup of empty directories" test -f "$HOME/.claude/$entry/.keep"
done
check "prompt history is shared" same "$(readlink "$home/history.jsonl")" "$HOME/.claude/history.jsonl"
check "the login metadata stays per account" test -f "$home/.claude.json" -a ! -L "$home/.claude.json"
check "live sessions are not linked" test ! -L "$home/sessions"
check "a throwaway cache is not linked" test ! -L "$home/image-cache"
check "an absent plugin directory is not created" test ! -e "$HOME/.claude/security"
check "the sign-in ran as the account" has "$(grep -l 'argv=auth login' "${calls}"/call.* | xargs cat)" "cfg=${home}"
check "the sign-in goes to the account browser" has "$(grep -l 'argv=auth login' "${calls}"/call.* | xargs cat)" "browser=$HOME/.local/bin/claude-account-browser"
check "the extension page opens in the account's profile" has "$(<"${calls}/open")" "[--profile-directory=Profile claude-work][https://claude.ai/chrome]"

before="$(stat -f %i "$home/settings.json")"
reset_calls
claude:add work >/dev/null
check "a repeated add signs in only once" fails grep -l 'argv=auth login' "${calls}"/call.*
check "a repeated add leaves links in place" same "$(stat -f %i "$home/settings.json")" "$before"

reset_calls
check "a failed sign-in reports failure" fails env STUB_LOGIN_FAILS=1 zsh -fc "source ${(q)repo}/dot_functions; claude:add broken"
check "a failed sign-in keeps the account for a retry" test -d "${accounts}/broken"
STUB_EMAIL=broken@example.com STUB_UUID=uuid-broken claude:add broken >/dev/null
check "a retry finishes the setup" test -f "${accounts}/broken/.signed-in"

for name in "${inherited[@]}"; do
  export "${name}=from-parent"
done
reset_calls
claude:as work -p "two words"
call="$(last_call)"
check "the config directory is the exact path" has "$call" $'\n'"cfg=${home}"$'\n'
check "plugins come from the primary root" has "$call" "plugins=$HOME/.claude/plugins"
check "sign-ins use the account browser" has "$call" "browser=$HOME/.local/bin/claude-account-browser"
check "no inherited login or session marker survives" hasnt "$call" "leak="
check "Console logins stay in the account" has "$call" "profiles=${home}/anthropic"
check "the alias flags come first" has "$call" "argv=--dangerously-skip-permissions --effort ultracode --remote-control --chrome "
check "shared MCP servers come from the primary file" has "$call" "--mcp-config=$HOME/.claude.json"
check "arguments come last" has "$call" " -p two words"$'\n'
check "the parent shell keeps its environment" same "${CLAUDE_CONFIG_DIR-<unset>}" "<unset>"
check "the parent shell gets no plugin root" same "${CLAUDE_CODE_PLUGIN_CACHE_DIR-<unset>}" "<unset>"
check "the parent shell keeps its own login" same "$ANTHROPIC_API_KEY" from-parent
unset "${inherited[@]}"

reset_calls
claude
check "plain claude stays on the primary" same "$(last_call | grep '^cfg=')" "cfg=<unset>"
check "plain claude gets no MCP flag" hasnt "$(last_call)" "--mcp-config"

mkdir -p "$HOME/proj"
ln -s "$HOME" "${tmp}/home-link"
reset_calls
( cd "$HOME" && claude:as work )
check "project settings are off from HOME" has "$(last_call)" "--setting-sources=user,local"
reset_calls
( cd "${tmp}/home-link" && claude:as work )
check "project settings are off through a link to HOME" has "$(last_call)" "--setting-sources=user,local"
reset_calls
( cd "$HOME/proj" && claude:as work )
check "project settings stay on anywhere else" hasnt "$(last_call)" "--setting-sources"

saved="${aliases[claude]}"
unalias claude
reset_calls
claude:as work
check "no alias means no flags and no crash" same "$(last_call | sed -n 's/^argv=//p')" "--mcp-config=$HOME/.claude.json"
alias claude="$saved"

mv "$HOME/.claude.json" "$HOME/.claude.json.keep"
print -r -- '{"numStartups":1}' > "$HOME/.claude.json"
reset_calls
claude:as work
check "no mcpServers key means no flag" hasnt "$(last_call)" "--mcp-config"
command rm "$HOME/.claude.json"
reset_calls
claude:as work
check "a missing primary file means no flag" hasnt "$(last_call)" "--mcp-config"
mv "$HOME/.claude.json.keep" "$HOME/.claude.json"

mkdir -p "$HOME/.agents/skills/gamma" "$HOME/.claude/agents"
ln -s "$HOME/.agents/skills/gamma" "$HOME/.claude/skills/gamma"
command rm "$HOME/.claude/skills/beta"
claude:as work
check "a new skill appears on the next launch" test -e "$home/skills/gamma"
check "a removed skill disappears" test ! -e "$home/skills/beta" -a ! -L "$home/skills/beta"
check "a new shared directory appears" same "$(readlink "$home/agents")" "$HOME/.claude/agents"
mkdir -p "$HOME/.claude/security"
claude:as work
check "plugin state is shared once it exists" same "$(readlink "$home/security")" "$HOME/.claude/security"

mkdir -p "$home/projects/-work-app/memory"
print -r -- '- from work' > "$home/projects/-work-app/memory/MEMORY.md"
print -r -- '{"display":"from work"}' >> "$home/history.jsonl"
claude:as broken
check "memory written by one account reaches the primary" test -f "$HOME/.claude/projects/-work-app/memory/MEMORY.md"
check "memory written by one account reaches another" same "$(<"${accounts}/broken/projects/-work-app/memory/MEMORY.md")" "- from work"
check "prompt history reaches another account" same "$(<"${accounts}/broken/history.jsonl")" '{"display":"from work"}'
claude:as work
check "a launch keeps the existing prompt history" same "$(<"$HOME/.claude/history.jsonl")" '{"display":"from work"}'

command rm -rf "$HOME/.claude/plans"
claude:as work
check "a deleted state directory returns at the next launch" test -d "$home/plans/."

command rm "$home/tasks"
mkdir "$home/tasks"
print -r -- own > "$home/tasks/own"
warning="$(claude:as work 2>&1)"
check "a real state directory is kept" test -f "$home/tasks/own"
check "a real state directory gets a warning" has "$warning" "$home/tasks, which other accounts cannot see"
command rm -rf "$home/tasks"
warning="$(claude:as work 2>&1)"
check "a removed state directory relinks" same "$(readlink "$home/tasks")" "$HOME/.claude/tasks"
check "a shared state directory gets no warning" same "$warning" ""
print -r -- '{"hooks":{"changed":true}}' > "$HOME/.claude/settings.json.new"
mv "$HOME/.claude/settings.json.new" "$HOME/.claude/settings.json"
check "a chezmoi-style replace reaches the account" has "$(<"$home/settings.json")" changed

mkdir -p "$home/skills/own"
print -r -- own > "$home/skills/own/SKILL.md"
command rm "$home/CLAUDE.md"
print -r -- '# own' > "$home/CLAUDE.md"
claude:as work
warning="$(claude:as work 2>&1)"
check "an account's own instructions survive" same "$(<"$home/CLAUDE.md")" "# own"
check "an account's own instructions get no warning" same "$warning" ""
check "an account's own skill survives" test -f "$home/skills/own/SKILL.md"
check "other accounts keep the shared file" same "$(readlink "${accounts}/broken/CLAUDE.md")" "$HOME/.claude/CLAUDE.md"
command rm "$home/CLAUDE.md"
claude:as work
check "a removed override relinks" same "$(readlink "$home/CLAUDE.md")" "$HOME/.claude/CLAUDE.md"

command rm "$home/settings.json"
print -r -- '{}' > "$home/settings.json"
reset_calls
check "a real settings.json blocks the launch" fails claude:as work
check "a blocked launch never reaches claude" same "$(call_count)" 0
command rm "$home/settings.json"

ln -s /nonexistent "$home/settings.json"
claude:as work
check "a wrong settings link is repaired" same "$(readlink "$home/settings.json")" "$HOME/.claude/settings.json"

command rm "$home/commands"
mkdir -p "${tmp}/elsewhere"
ln -s "${tmp}/elsewhere" "$home/commands"
claude:as work
check "a wrong link to a directory is replaced" same "$(readlink "$home/commands")" "$HOME/.claude/commands"
check "a repair never writes through the old link" test ! -e "${tmp}/elsewhere/commands"

mv "$HOME/.claude/settings.json" "$HOME/.claude/settings.keep"
reset_calls
check "missing shared settings block the launch" fails claude:as work
check "missing settings never reach claude" same "$(call_count)" 0
mv "$HOME/.claude/settings.keep" "$HOME/.claude/settings.json"

reset_calls
for i in {1..8}; do
  claude:as work -p "w$i" &
  claude:as broken -p "b$i" &
done
wait
check "parallel launches all ran" same "$(call_count)" 16
check "work launches kept their account" same "$(cat "${calls}"/call.*(.) | grep -c "^cfg=${home}$")" 8
check "broken launches kept their account" same "$(cat "${calls}"/call.*(.) | grep -c "^cfg=${accounts}/broken$")" 8
check "parallel launches kept the settings link" test "$home/settings.json" -ef "$HOME/.claude/settings.json"

# Launches race to create the same links, and losing that race must not stop one
mkdir -p "$HOME/.agents/skills/delta" "${accounts}/racing"
ln -s "$HOME/.agents/skills/delta" "$HOME/.claude/skills/delta"
reset_calls
for i in {1..12}; do
  claude:as racing -p "r$i" &
done
wait
check "racing first launches all ran" same "$(call_count)" 12
check "racing launches created the settings link" test "${accounts}/racing/settings.json" -ef "$HOME/.claude/settings.json"
check "racing launches created the skill links" same "$(readlink "${accounts}/racing/skills/delta")" "$HOME/.claude/skills/delta"
command rm -rf "${accounts}/racing"

print -r -- '{"mcpServers":{},"oauthAccount":{"emailAddress":"me@example.com","organizationName":"Mine","accountUuid":"uuid-me"}}' > "$HOME/.claude.json"
listing="$(claude:accounts 2>&1)"
check "the primary is listed" has "$listing" "(primary)"
check "the primary shows its identity" has "$listing" "me@example.com"
check "an account shows its identity" has "$listing" "work@example.com"
check "an account without a profile says so" has "$listing" "no profile"
check "distinct identities raise no warning" hasnt "$listing" "Warning"

mkdir -p "$accounts/fresh"
listing="$(claude:accounts 2>&1)"
check "an account without a login reads as signed out" has "$listing" "(signed out)"

profiles="$HOME/Library/Application Support/Google/Chrome"
mkdir -p "$profiles/Profile claude-work"
check "a profile without the extension says so" has "$(claude:accounts 2>&1)" "no extension"
mkdir -p "$profiles/Profile claude-work/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn"
check "a profile with the extension says so" has "$(claude:accounts 2>&1)" "extension installed"

print -r -- '{"oauthAccount":{"emailAddress":"solo@example.com","accountUuid":"uuid-solo"}}' > "$accounts/fresh/.claude.json"
check "a missing organization keeps the columns" has "$(claude:accounts 2>&1 | grep '^fresh')" "(none)"
print -r -- '{"oauthAccount":{"organizationName":"Named","accountUuid":"uuid-noemail"}}' > "$accounts/fresh/.claude.json"
check "a missing email keeps the organization in its column" has "$(claude:accounts 2>&1 | grep '^fresh' | tr -s ' ')" "(signed out) Named"

print -r -- '{"oauthAccount":{"emailAddress":"me@example.com","organizationName":"Mine","accountUuid":"uuid-me"}}' > "$accounts/fresh/.claude.json"
check "a duplicate identity is flagged" has "$(claude:accounts 2>&1)" "Detected fresh and (primary) on one claude.ai account"
mkdir -p "$accounts/third"
cp "$accounts/fresh/.claude.json" "$accounts/third/.claude.json"
check "every duplicate is flagged" has "$(claude:accounts 2>&1)" "Detected third and (primary) on one claude.ai account"
command rm -rf "$accounts/third"

reset_calls
claude:chrome work https://example.com/
check "a URL opens in the account's profile" same "$(<"${calls}/open")" "[-na][Google Chrome][--args][--profile-directory=Profile claude-work][https://example.com/]"
reset_calls
claude:chrome work http://localhost:3000/
check "a plain http URL opens in the profile too" same "$(<"${calls}/open")" "[-na][Google Chrome][--args][--profile-directory=Profile claude-work][http://localhost:3000/]"
reset_calls
claude:chrome work
check "no URL opens just the profile" same "$(<"${calls}/open")" "[-na][Google Chrome][--args][--profile-directory=Profile claude-work]"
check "claude:chrome refuses an unknown account" fails claude:chrome nobody
check "the browser script refuses to guess an account" fails "$HOME/.local/bin/claude-account-browser"
reset_calls
CLAUDE_CONFIG_DIR="$home" "$HOME/.local/bin/claude-account-browser" vscode://file/x
check "an app link skips Chrome" same "$(<"${calls}/open")" "[vscode://file/x]"
reset_calls
claude:add work >/dev/null
check "an installed extension needs no install page" test ! -e "${calls}/open"

# Claude Code's Bash tool sources a snapshot that drops functions named _* and
# plain variables, so that is the environment these have to work from.
snapshot="${tmp}/snapshot.zsh"
zsh -fc "source ${(q)repo}/dot_functions; typeset +f | grep -vE '^_[^_]' | while read -r name; do typeset -f \"\$name\"; done" > "$snapshot"
listing="$(zsh -fc "source ${(q)snapshot}; setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL; claude:accounts" 2>&1)"
check "claude:accounts works from a snapshot" has "$listing" "work@example.com"
check "claude:accounts stays inside the accounts directory" hasnt "$listing" "Applications"
check "claude:accounts finds every helper in a snapshot" hasnt "$listing" "command not found"
reset_calls
zsh -fc "source ${(q)snapshot}; setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL; claude:as work -p snapshot" &>/dev/null
check "claude:as works from a snapshot" has "$(last_call)" "cfg=${home}"

mkdir -p "$home/sessions"
print -r -- '{}' > "$home/sessions/$$.json"
reset_calls
check "a running session blocks removal" fails answer y claude:remove work
check "a blocked removal never signs out" same "$(call_count)" 0
check "a blocked removal keeps the account" test -d "$home"
command rm "$home/sessions/$$.json"
print -r -- '{}' > "$home/sessions/999999.json"

reset_calls
print -r -- n | claude:remove work >/dev/null
check "a refusal changes nothing" test -d "$home" -a -f "$home/.signed-in"

check "a failed sign-out stops the removal" fails env STUB_LOGOUT_FAILS=1 zsh -fc "source ${(q)repo}/dot_functions; print y | claude:remove work"
check "a failed sign-out keeps the directory" test -d "$home"

check "a failed Trash reports failure" fails env PATH="${tmp}/no-trash:$PATH" zsh -fc "source ${(q)repo}/dot_functions; print y | claude:remove broken"
check "a failed Trash keeps the directory" test -d "${accounts}/broken"
: > "${accounts}/broken/.signed-in"

print -r -- y | claude:remove work >/dev/null
check "removal signs out first" test ! -f "${calls}/trashed-work/.signed-in"
check "removal moves the directory to the Trash" same "$(<"${calls}/trash")" "$home"
check "removal leaves the other account alone" test -f "${accounts}/broken/.signed-in"
check "removal leaves the shared configuration alone" test -f "$HOME/.claude/settings.json"
check "removal leaves memory and history for the others" test -f "$HOME/.claude/projects/-work-app/memory/MEMORY.md"
command rm -rf "${accounts}/fresh/sessions"
print -r -- y | claude:remove fresh >/dev/null
check "an account with no sessions directory can be removed" test ! -e "${accounts}/fresh"

hooks="$HOME/.claude/hooks"
mkdir -p "$hooks" "$accounts/mem" "$HOME/.claude/projects/-app/memory"
for name in lock-memory-writes guard-live-sessions; do
  cp "${repo}/private_dot_claude/private_hooks/private_executable_${name}.sh" "${hooks}/${name}.sh"
  chmod +x "${hooks}/${name}.sh"
done
claude:as mem
memory="$HOME/.claude/projects/-app/memory"
linked="$accounts/mem/projects/-app/memory"
lock="${memory}/.write-lock"
template="${repo}/private_dot_claude/private_settings.json.tmpl"

# These run from this shell, so $$ is the session a hook sees as its parent
memory_hook() {
  jq -n --arg e "$1" --arg t "$2" --arg i "$3" --arg p "$4" \
    '{hook_event_name: $e, tool_name: $t, tool_use_id: $i, tool_input: {file_path: $p}}' \
    | "${hooks}/lock-memory-writes.sh"
}

print -r -- '- one' > "${memory}/MEMORY.md"
check "an edit takes the lock" memory_hook PreToolUse Edit t1 "${memory}/MEMORY.md"
check "the lock names its owner" same "$(readlink "$lock")" "t1 $$"
memory_hook PostToolUse Edit other "${memory}/MEMORY.md"
check "another call's result leaves the lock" test -L "$lock"
memory_hook PostToolUse Edit t1 "${memory}/MEMORY.md"
check "the call's result releases the lock" test ! -L "$lock"

check "an account's spelling locks the real store" memory_hook PreToolUse Edit t2 "${linked}/MEMORY.md"
check "the lock sits in the real store" same "$(readlink "$lock")" "t2 $$"
memory_hook PostToolUseFailure Edit t2 "${linked}/MEMORY.md"
check "a failed call releases the lock" test ! -L "$lock"

memory_hook PreToolUse Write t3 "${memory}/MEMORY.md" 2>/dev/null
check "a Write over a memory is blocked" same "$?" 2
check "a blocked Write leaves no lock" test ! -L "$lock"
check "a blocked Write names the way out" has "$(memory_hook PreToolUse Write t3 "${linked}/MEMORY.md" 2>&1)" "Change it with Edit"
check "a Write of a new memory passes" memory_hook PreToolUse Write t4 "${memory}/new.md"
memory_hook PostToolUse Write t4 "${memory}/new.md"
: > "${memory}/empty.md"
check "a Write over an empty file passes" memory_hook PreToolUse Write t5 "${memory}/empty.md"
memory_hook PostToolUse Write t5 "${memory}/empty.md"
mkdir -p "$accounts/mem/agent-memory/reviewer" "${tmp}/repo/.claude/agent-memory/reviewer"
print -r -- note > "$accounts/mem/agent-memory/reviewer/MEMORY.md"
print -r -- note > "${tmp}/repo/.claude/agent-memory/reviewer/MEMORY.md"
check "agent memory is covered" fails memory_hook PreToolUse Write t6 "$accounts/mem/agent-memory/reviewer/MEMORY.md"
check "project agent memory is covered" fails memory_hook PreToolUse Write t7 "${tmp}/repo/.claude/agent-memory/reviewer/MEMORY.md"
mkdir -p "$HOME/work/memory" "$HOME/.claude/projects/-app"
print -r -- code > "$HOME/work/memory/notes.md"
print -r -- log > "$HOME/.claude/projects/-app/session.jsonl"
check "an ordinary memory folder is left alone" memory_hook PreToolUse Write t8 "$HOME/work/memory/notes.md"
check "a transcript is left alone" memory_hook PreToolUse Write t9 "$HOME/.claude/projects/-app/session.jsonl"
check "an ordinary file takes no lock" test ! -L "$HOME/work/memory/.write-lock"

dead="$(zsh -fc 'print -r -- $$')"
ln -s "old ${dead}" "$lock"
waited=$SECONDS
check "a dead holder loses the lock" memory_hook PreToolUse Edit t10 "${memory}/MEMORY.md"
check "a dead holder is not waited for" test $(( SECONDS - waited )) -lt 3
check "the new owner took over" same "$(readlink "$lock")" "t10 $$"
memory_hook PostToolUse Edit t10 "${memory}/MEMORY.md"

sleep 120 &
live=$!
ln -s "stuck ${live}" "$lock"
check "a stuck holder loses the lock" memory_hook PreToolUse Edit t11 "${memory}/MEMORY.md"
check "the waiter took over" same "$(readlink "$lock")" "t11 $$"
memory_hook PostToolUse Edit t11 "${memory}/MEMORY.md"

# Without the lock these sessions lose lines almost every run
cat > "${tmp}/session" <<'SESSION'
#!/bin/bash
event() {
  jq -n --arg e "$1" --arg i "$who-$round" --arg p "$file" \
    '{hook_event_name: $e, tool_name: "Edit", tool_use_id: $i, tool_input: {file_path: $p}}' | "$hook" || exit 1
}
hook=$1 file=$2 real=$3 who=$4
for round in 1 2 3 4 5 6 7 8; do
  event PreToolUse
  before=$(<"$real")
  sleep 0.003
  printf '%s\n- %s-%s\n' "$before" "$who" "$round" >"$real.$who"
  mv "$real.$who" "$real"
  event PostToolUse
done
SESSION
chmod +x "${tmp}/session"
print -r -- '# index' > "${memory}/race.md"
writers=()
for who in a b; do "${tmp}/session" "${hooks}/lock-memory-writes.sh" "${memory}/race.md" "${memory}/race.md" "$who" & writers+=( $! ); done
for who in c d; do "${tmp}/session" "${hooks}/lock-memory-writes.sh" "${linked}/race.md" "${memory}/race.md" "$who" & writers+=( $! ); done
wait "${writers[@]}"
check "no concurrent update is lost" same "$(grep -c '^- ' "${memory}/race.md")" 32
check "the race leaves no lock" test ! -L "$lock"

# Every session sees the same stale lock at once, so all of them try to take it
# over
print -r -- '# index' > "${memory}/takeover.md"
for attempt in 1 2 3 4 5 6; do
  ln -s "gone ${dead}" "$lock"
  writers=()
  for who in a${attempt} b${attempt} c${attempt} d${attempt}; do
    "${tmp}/session" "${hooks}/lock-memory-writes.sh" "${memory}/takeover.md" "${memory}/takeover.md" "$who" & writers+=( $! )
  done
  wait "${writers[@]}"
done
check "a contended takeover loses no update" same "$(grep -c '^- ' "${memory}/takeover.md")" 192
check "a takeover leaves nothing behind" test ! -L "$lock" -a ! -L "${lock}.takeover"

ln -s "gone ${dead}" "$lock"
ln -s "stale $$" "${lock}.takeover"
sleep 120 &
stuck=$!
command rm -f "$lock"
ln -s "stuck ${stuck}" "$lock"
memory_hook PreToolUse Edit t12 "${memory}/MEMORY.md" 2>/dev/null
check "a wedged takeover refuses the call" same "$?" 2
check "a refused call clears the wedge" test ! -L "${lock}.takeover"
kill "$stuck" 2>/dev/null
command rm -f "$lock"

mkdir -p "${tmp}/locked/.claude/agent-memory/x"
print -r -- note > "${tmp}/locked/.claude/agent-memory/x/n.md"
chmod 500 "${tmp}/locked/.claude/agent-memory/x"
waited=$SECONDS
check "an unwritable store is left alone" memory_hook PreToolUse Edit t13 "${tmp}/locked/.claude/agent-memory/x/n.md"
check "an unwritable store does not spin" test $(( SECONDS - waited )) -lt 3
chmod 700 "${tmp}/locked/.claude/agent-memory/x"

owners="$HOME/.claude/session-owners"
guard="${hooks}/guard-live-sessions.sh"
session_hook() {
  jq -n --arg e "$1" --arg s "$2" --arg c "${3:-/work}" '{hook_event_name: $e, session_id: $s, cwd: $c}' | "$guard"
}
owner_record() { printf '%s\n' "$2" "${5-$(ps -o lstart= -p "$2")}" "$3" "$4" > "${owners}/$1"; }
# Not through $(...), whose subshell would be a different parent for the hook
session_quiet() { session_hook "$@" > "${tmp}/hook.out"; [[ ! -s "${tmp}/hook.out" ]]; }

check "a new session stays quiet" session_quiet SessionStart s1
check "a session records its owner" same "$(sed -n 1p "${owners}/s1")" "$$"
check "the primary is named" same "$(sed -n 3p "${owners}/s1")" "primary"
check "the directory is recorded" same "$(sed -n 4p "${owners}/s1")" "/work"
check "its own prompt passes" session_quiet UserPromptSubmit s1
CLAUDE_CONFIG_DIR="$accounts/mem" session_hook SessionStart s2 > "${tmp}/hook.out"
check "an account is named" same "$(sed -n 3p "${owners}/s2")" "mem"
check "an account states itself to the session" has "$(jq -r .hookSpecificOutput.additionalContext "${tmp}/hook.out")" "account mem."

owner_record s3 "$live" other /work
output="$(session_hook UserPromptSubmit s3)"
check "a prompt to a live session is blocked" same "$(jq -r .decision <<<"$output")" block
check "the block names the owner" has "$output" "process ${live} (other)"
check "the block keeps the prompt out of its message" same "$(jq -r .hookSpecificOutput.suppressOriginalPrompt <<<"$output")" true
check "the block offers a copy" has "$output" "/branch"
check "a block leaves the owner in place" same "$(sed -n 1p "${owners}/s3")" "$live"
check "opening a live session warns" has "$(session_hook SessionStart s3 | jq -r .systemMessage)" "live in process ${live}"
session_hook SessionEnd s3
check "another session's end leaves the record" test -f "${owners}/s3"
owner_record s3b "$$" self /work
session_hook SessionEnd s3b
check "a record padded like ps output still matches" test ! -e "${owners}/s3b"
session_hook SessionEnd s1
check "a session's end clears its record" test ! -e "${owners}/s1"

owner_record s4 "$dead" gone /work
check "a dead owner blocks nothing" session_quiet UserPromptSubmit s4
check "the next session takes over" same "$(sed -n 1p "${owners}/s4")" "$$"
owner_record s5 "$live" other /work "Thu Jan  1 00:00:00 1970"
check "a reused pid blocks nothing" session_quiet UserPromptSubmit s5

live_id=11111111-2222-4333-8444-555555555555
free_id=99999999-2222-4333-8444-555555555555
owner_record "$live_id" "$live" other /work
owner_record s7 "$dead" gone /work
check "a neighbour in the directory is named" has "$(session_hook SessionStart s8 /work | jq -r .systemMessage)" "process ${live} (other)"
check "the warning points at worktrees" has "$(session_hook SessionStart s9 /work | jq -r .systemMessage)" "--worktree"
check "a session elsewhere stays quiet" session_quiet SessionStart s10 /elsewhere
check "a start clears records of dead sessions" test ! -e "${owners}/s7"

check "a live directory is found" has "$("$guard" live /work)" "(other)"
check "a live session is found by id" has "$("$guard" live /elsewhere "$live_id")" "(other)"
check "nothing live elsewhere" fails "$guard" live /nowhere
check "a named session ignores the directory" fails "$guard" live /work "$free_id"

mkdir -p "${tmp}/here"
owner_record s11 "$live" other "${tmp:A}/here"
fork_flag() { ( cd "$1" && shift && claude:_fork-live "$@" 2>/dev/null ); }
check "--continue forks beside a live session" same "$(fork_flag "${tmp}/here" --continue)" "--fork-session"
check "-c forks beside a live session" same "$(fork_flag "${tmp}/here" -p hi -c)" "--fork-session"
check "the picker forks beside a live session" same "$(fork_flag "${tmp}/here" --resume)" "--fork-session"
check "a live id forks from anywhere" same "$(fork_flag / --resume "$live_id")" "--fork-session"
check "a live transcript path forks from anywhere" same "$(fork_flag / -r "/x/y/${live_id}.jsonl")" "--fork-session"
check "--resume=<path> forks from anywhere" same "$(fork_flag / "--resume=/x/y/${live_id}.jsonl")" "--fork-session"
check "a session nobody holds is not forked" same "$(fork_flag "${tmp}/here" --resume "$free_id")" ""
check "a session name counts as none named" same "$(fork_flag "${tmp}/here" --resume my-session)" "--fork-session"
check "a flag after --resume counts as none named" same "$(fork_flag "${tmp}/here" --resume -p hi)" "--fork-session"
check "a new session is not forked" same "$(fork_flag "${tmp}/here" -p hi)" ""
check "an explicit fork is not doubled" same "$(fork_flag "${tmp}/here" --continue --fork-session)" ""

reset_calls
( cd "${tmp}/here" && claude:as mem --continue >/dev/null )
check "claude:as forks a live session" has "$(last_call)" "--fork-session --continue"
reset_calls
( cd "${tmp}/here" && claude --continue >/dev/null )
check "plain claude forks a live session" has "$(last_call)" "--fork-session --dangerously-skip-permissions"
reset_calls
( cd / && claude --continue >/dev/null )
check "plain claude adds nothing elsewhere" hasnt "$(last_call)" "--fork-session"
reset_calls
( cd "${tmp}/here" && claude:_run "$accounts/mem" claude --continue >/dev/null )
check "claude:_run runs the binary, not the claude function" hasnt "$(last_call)" "--fork-session"
kill "$live" 2>/dev/null

solo="${tmp}/solo"
mkdir -p "${solo}/.claude/hooks" "${solo}/.claude/projects/-app/memory"
cp "${hooks}"/*.sh "${solo}/.claude/hooks/"
print -r -- note > "${solo}/.claude/projects/-app/memory/MEMORY.md"
print -r -- '{"hook_event_name":"SessionStart","session_id":"s","cwd":"/work"}' > "${tmp}/start.json"
jq -n --arg p "${solo}/.claude/projects/-app/memory/MEMORY.md" \
  '{hook_event_name: "PreToolUse", tool_name: "Write", tool_use_id: "t", tool_input: {file_path: $p}}' > "${tmp}/write.json"
check "without accounts Write is left alone" env HOME="$solo" "${solo}/.claude/hooks/lock-memory-writes.sh" < "${tmp}/write.json"
check "without accounts no lock appears" test ! -L "${solo}/.claude/projects/-app/memory/.write-lock"
check "without accounts the guard exits cleanly" env HOME="$solo" "${solo}/.claude/hooks/guard-live-sessions.sh" < "${tmp}/start.json"
check "without accounts nothing is recorded" test ! -e "${solo}/.claude/session-owners"
check "without accounts nothing counts as live" fails env HOME="$solo" "${solo}/.claude/hooks/guard-live-sessions.sh" live /work

registered() {
  python3 -I -c '
import sys
text = open(sys.argv[1]).read()
block = text[text.index(chr(34) + sys.argv[2] + chr(34) + ": ["):]
sys.exit(sys.argv[3] not in block[:block.index("\n    ]")])' "$template" "$1" "$2"
}
for event in PreToolUse PostToolUse PostToolUseFailure; do
  check "${event} runs the memory lock" registered "$event" lock-memory-writes.sh
done
for event in SessionStart UserPromptSubmit SessionEnd; do
  check "${event} runs the session guard" registered "$event" guard-live-sessions.sh
done

print -r -- "${passed} passed, ${failed} failed"
(( failed == 0 ))
