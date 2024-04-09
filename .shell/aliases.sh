if cmd:exists xclip; then
  alias xc="xclip -selection c"
  alias xp="xclip -selection clipboard -o"
elif cmd:exists termux-clipboard-get; then
  alias xc="termux-clipboard-get"
  alias xp="termux-clipboard-set"
fi

cmd:exists lsd && alias ls='lsd'
cmd:exists btop && alias top='btop'
cmd:exists bat && alias cat='bat'

if cmd:exists nvim; then
  alias vi=nvim
  alias vim=nvim
fi

alias python='python3'
alias dirs="dirs -v"
alias ssh='ssh -o AddKeysToAgent=yes'
alias bash="PERMIT_BASH=true bash"

alias ez="${EDITOR} ${HOME}/.zshrc"
alias es="${EDITOR} ${HOME}/bashrc"
alias ef="${EDITOR} ${HOME}/.shell/func.sh"
alias ev="${EDITOR} ${HOME}/.shell/vars.sh"
alias ea="${EDITOR} ${HOME}/.shell/aliases.sh"
alias e="${EDITOR} ."

alias -s go="${EDITOR}"
alias -s md="${EDITOR}"
alias -s yaml="${EDITOR}"
alias -s yml="${EDITOR}"
alias -s js="${EDITOR}"
alias -s ts="${EDITOR}"
alias -s json="${EDITOR}"
