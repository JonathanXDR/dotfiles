# Amazon Q pre block. Keep at the top of this file.
[[ -f "${HOME}/Library/Application Support/amazon-q/shell/bashrc.pre.bash" ]] && builtin source "${HOME}/Library/Application Support/amazon-q/shell/bashrc.pre.bash"
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"                                       # This loads nvm
[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" # This loads nvm bash_completion

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

[[ -f "$HOME/.fig/export/dotfiles/dotfile.bash" ]] && source "$HOME/.fig/export/dotfiles/dotfile.bash"

# Amazon Q post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/amazon-q/shell/bashrc.post.bash" ]] && builtin source "${HOME}/Library/Application Support/amazon-q/shell/bashrc.post.bash"
