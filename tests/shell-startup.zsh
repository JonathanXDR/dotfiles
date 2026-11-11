#!/bin/zsh -f
# Run with `zsh -f tests/shell-startup.zsh`. HOME is a throwaway directory that
# links the repo's shell files, antidote reads its existing clones, fresh stamps
# keep run:daily from updating anything, and a stub stands in for atuin, so
# nothing reaches the network or the real home directory.

repo="${0:A:h:h}"
antidote_home="${ANTIDOTE_HOME:-$HOME/Library/Caches/antidote}"
[[ -d "$antidote_home" ]] || { print -r -- "Missing antidote clones in ${antidote_home} (open one terminal first)"; exit 1; }
command -v chezmoi >/dev/null || { print -r -- "Missing chezmoi, which renders the history settings"; exit 1; }

tmp="$(mktemp -d)"
trap 'command rm -rf -- "$tmp"' EXIT
home="${tmp}/home"
mkdir -p "$home/.local/bin" "$home/.local/share/mise/shims" "$home/.cache/daily"
touch "$home"/.cache/daily/{mise,brew,plugins}
for f in zshenv zprofile zshrc functions aliases completions plugins; do
  ln -s "${repo}/dot_${f}" "$home/.${f}"
done

# The full template reads the keychain, so only its history settings render
{
  print -r -- 'export EDITOR=vi'
  sed -n '/^HISTSIZE=/,/^}/p' "${repo}/private_dot_exports.tmpl" | chezmoi --source "$repo" execute-template
} > "$home/.exports" || exit 1

cat > "$home/.local/bin/atuin" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$HOME/atuin-calls"
[ "$1" = init ] && printf '%s\n' 'ZSH_AUTOSUGGEST_STRATEGY=(atuin $ZSH_AUTOSUGGEST_STRATEGY)' \
  'atuin-search() { :; }' 'zle -N atuin-search' 'bindkey "^R" atuin-search'
exit 0
STUB
chmod +x "$home/.local/bin/atuin"

probe="${tmp}/probe.zsh"
cat > "$probe" <<'PROBE'
print -r -- "galiases=${#galiases}"
local -aU unique
unique=( $path ); print -r -- "path_dupes=$(( ${#path} - ${#unique} ))"
unique=( $fpath ); print -r -- "fpath_dupes=$(( ${#fpath} - ${#unique} ))"
local hook
local -a fns
for hook in precmd preexec chpwd zshaddhistory; do
  fns=( ${(P)${:-${hook}_functions}} ); unique=( $fns )
  print -r -- "${hook}_dupes=$(( ${#fns} - ${#unique} ))"
done
print -r -- "keymap=$(bindkey -lL main)"
local name seq
for name seq in up '^[[A' up_app '^[OA' alt_up '^[[1;3A' alt_up_esc '^[^[[A' \
    down '^[[B' down_app '^[OB' alt_down '^[[1;3B' alt_down_esc '^[^[[B' \
    shift_tab '^[[Z' ctrl_r '^R'; do
  print -r -- "key_${name}=$(bindkey "$seq")"
done
print -r -- "menu_shift_tab=$(bindkey -M menuselect '^[[Z')"
local v; zstyle -s ':completion:*' menu v; print -r -- "menu=${v}"
[[ -o listbeep ]] && print -r -- "listbeep=on" || print -r -- "listbeep=off"
print -r -- "manual_rebind=${+ZSH_AUTOSUGGEST_MANUAL_REBIND}"
print -r -- "strategy=${ZSH_AUTOSUGGEST_STRATEGY[*]}"
print -r -- "removed_widgets=$(( ${+widgets[fzf-history-widget]} + ${+widgets[recent-paths]} ))"
print -r -- "comp git=${_comps[git]}"
print -r -- "comp claude:as=${_comps[claude:as]}"
print -r -- "figxit=${+functions[figxit]}"
print -r -- "keytimeout=${KEYTIMEOUT}"
print -r -- "clear_widgets=${ZSH_AUTOSUGGEST_CLEAR_WIDGETS[*]}"
local -i i=0
local line
for line in 'claude --resume' '\claude --dangerously-skip-permissions x' '\codex --yolo' \
    'gh copilot suggest' 'echo claude' 'xclaude'; do
  (( i++ ))
  zshaddhistory "${line}"$'\n' && print -r -- "history_${i}=kept" || print -r -- "history_${i}=dropped"
done
source "$HOME/.functions" 2>"$HOME/resource.err"
print -r -- "resource=$? $(<$HOME/resource.err)"
PROBE

run() {
  cd "$home" && env -i HOME="$home" USER="$USER" TERM=xterm-256color SHELL=/bin/zsh \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin ANTIDOTE_HOME="$antidote_home" \
    FIGXIT_SOCK="${tmp}/figxit.sock" PROBE="$probe" "$@" </dev/null 2>"${tmp}/stderr"
}

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
same() { [[ "$1" == "$2" ]] || { print -r -- "  expected: $2"; print -r -- "  actual:   $1"; return 1; }; }
has() { [[ "$1" == *"$2"* ]] || { print -r -- "  missing '$2' in: $1"; return 1; }; }

typeset -A r
load() { r=(); local l; for l in ${(f)1}; do r[${l%%=*}]="${l#*=}"; done; }

figxit_engine=/Applications/Figxit.app/Contents/MacOS/figxit-engine

interactive_checks() {
  local shell="$1"
  check "${shell}: starts without stderr" same "$(<"${tmp}/stderr")" ""
  check "${shell}: no global aliases" same "${r[galiases]}" 0
  check "${shell}: PATH has no duplicates" same "${r[path_dupes]}" 0
  check "${shell}: fpath has no duplicates" same "${r[fpath_dupes]}" 0
  local hook
  for hook in precmd preexec chpwd zshaddhistory; do
    check "${shell}: ${hook} hooks are unique" same "${r[${hook}_dupes]}" 0
  done
  check "${shell}: emacs keymap even with EDITOR=vi" same "${r[keymap]}" "bindkey -A emacs main"
  local name seq
  for name seq in up '^[[A' up_app '^[OA' alt_up '^[[1;3A' alt_up_esc '^[^[[A'; do
    check "${shell}: ${name} searches history up" same "${r[key_${name}]}" "\"${seq}\" history-substring-search-up"
  done
  for name seq in down '^[[B' down_app '^[OB' alt_down '^[[1;3B' alt_down_esc '^[^[[B'; do
    check "${shell}: ${name} searches history down" same "${r[key_${name}]}" "\"${seq}\" history-substring-search-down"
  done
  check "${shell}: Shift-Tab goes back" same "${r[key_shift_tab]}" '"^[[Z" reverse-menu-complete'
  check "${shell}: Shift-Tab goes back in the menu" same "${r[menu_shift_tab]}" '"^[[Z" reverse-menu-complete'
  check "${shell}: Ctrl-R opens Atuin" same "${r[key_ctrl_r]}" '"^R" atuin-search'
  check "${shell}: completion menu selects" same "${r[menu]}" select
  check "${shell}: ambiguous Tab stays quiet" same "${r[listbeep]}" off
  check "${shell}: autosuggestions bind once" same "${r[manual_rebind]}" 1
  check "${shell}: suggestions come from zsh history" same "${r[strategy]}" history
  check "${shell}: fzf and zsh-autocomplete stay gone" same "${r[removed_widgets]}" 0
  check "${shell}: compinit registers git" has "${r[comp git]}" _git
  check "${shell}: deferred compdefs replay" same "${r[comp claude:as]}" _claude_accounts
  check "${shell}: re-sourcing .functions is clean" same "${r[resource]}" "0 "
  # Same order as the probe: four ignored commands, then two that must stay
  local -i i
  for i in 1 2 3 4; do
    check "${shell}: history drops sample ${i}" same "${r[history_${i}]}" dropped
  done
  check "${shell}: history keeps a plain command" same "${r[history_5]}" kept
  check "${shell}: history keeps a longer word" same "${r[history_6]}" kept
  if [[ -x "$figxit_engine" ]]; then
    check "${shell}: Figxit loads" same "${r[figxit]}" 1
    check "${shell}: Esc Esc keeps a usable wait" same "${r[keytimeout]}" 30
    check "${shell}: Figxit's Enter clears the suggestion" has " ${r[clear_widgets]} " " figxit-enter "
  fi
}

load "$(run /bin/zsh -i -c 'source "$PROBE"')"
interactive_checks interactive
check "atuin init keeps Up and AI keys off" has "$(<"$home/atuin-calls")" "init zsh --disable-up-arrow --disable-ai"

load "$(run /bin/zsh -i -l -c 'source "$PROBE"')"
interactive_checks login

# The outer shell exports EDITOR=vi, FPATH and PATH, as `reload` and tmux do
load "$(run /bin/zsh -i -c 'zsh -i -c "source \$PROBE"')"
interactive_checks nested

load "$(run TERM_PROGRAM=zed /bin/zsh -i -c 'source "$PROBE"')"
interactive_checks zed

out="$(run /bin/zsh -c 'print -r -- "${path[1]} $+functions[plugins:load]"')"
check "zsh -c puts the mise shims first and skips .zshrc" same "$out" "${home}/.local/share/mise/shims 0"
out="$(cd "$home" && env -i HOME="$home" PATH="/opt/real/bin:${home}/.local/share/mise/shims:/usr/bin:/bin" /bin/zsh -c 'print -r -- $path[1]')"
check "zsh -c keeps inherited shims behind real tool directories" same "$out" /opt/real/bin
(cd "$home" && env -i HOME="$home" PATH="/opt/real/bin:${home}/.local/share/mise/shims:/usr/bin:/bin" /bin/zsh -c 'exit')
check "zsh -c with inherited shims exits 0" same "$?" 0

print -r -- "${passed} passed, ${failed} failed"
(( failed == 0 ))
