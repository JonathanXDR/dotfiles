# Amazon Q pre block. Keep at the top of this file.
[[ -f "${HOME}/Library/Application Support/amazon-q/shell/zshrc.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/amazon-q/shell/zshrc.pre.zsh"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"                   # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion

# Setting PATH for Python 3.12
# The original version is saved in .zprofile.pysave

eval "$(pyenv init --path)"
autoload -U add-zsh-hook

# bun completions
[ -s "/Users/jonathan/.bun/_bun" ] && source "/Users/jonathan/.bun/_bun"

# Load custom files
for file in vars func aliases; do
  [[ ! -f "${HOME}/.shell/${file}.sh" ]] || source "${HOME}/.shell/${file}.sh"
done

add-zsh-hook chpwd nvmrc:load
nvm:update
nvmrc:load
proxy:probe

# Set up proxy if in VPN or not
[[ "${ALWAYS_PROXY_PROBE}" == "true" ]]

# Load Angular CLI autocompletion.
source <(ng completion script)

[[ -f "$HOME/.fig/export/dotfiles/dotfile.zsh" ]] && builtin source "$HOME/.fig/export/dotfiles/dotfile.zsh"

# Amazon Q post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/amazon-q/shell/zshrc.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/amazon-q/shell/zshrc.post.zsh"
