#!/bin/zsh -f
# Regression tests for the claude:* account functions in dot_functions.
#
# Run with `zsh -f tests/claude-accounts.zsh`. HOME is a throwaway directory and
# stubs stand in for claude, open and trash, so nothing here can reach a real
# login, keychain item or browser. The stub records its arguments and the
# environment it was started with, which is what the account functions control.

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
# One file per call. auth subcommands keep a marker in the config directory.
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

# The stub writes one file per call. These clear, read and count them.
reset_calls() { command rm -f "${calls}"/call.*(N) "${calls}/open"; }
last_call() { cat "${calls}"/call.*(om[1]); }
call_count() { local -a c=( "${calls}"/call.*(N) ); print -r -- ${#c}; }

# --------------------------------- Names ---------------------------------- #

for bad in '' '../x' 'a/b' 'Upper' '-x' '.' '..' 'a b' 'a.b'; do
  check "claude:add rejects '${bad}'" fails claude:add "$bad"
done
check "a rejected name creates nothing" test ! -e "$accounts"
# The directory has to exist, or -d rejects these paths before any name check.
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

# ---------------------------------- Add ----------------------------------- #

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

# ---------------------------------- Launch --------------------------------- #

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

# ------------------------------- Propagation ------------------------------- #

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

# ------------------------------- Shared record ----------------------------- #

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

# ---------------------------------- Guards --------------------------------- #

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

# ------------------------------- Concurrency ------------------------------- #

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

# Launches race to create the same links, and losing that race must not stop one.
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

# ---------------------------------- Listing -------------------------------- #

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

# ---------------------------------- Chrome --------------------------------- #

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

# ---------------------------------- Remove --------------------------------- #

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

print -r -- "${passed} passed, ${failed} failed"
(( failed == 0 ))
