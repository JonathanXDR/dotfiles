### zsh-completions
if [ -d "$HOME/.fig/plugins/zsh-completions" ]; then

    source "$HOME/.fig/plugins/zsh-completions/zsh-completions.plugin.zsh"
    autoload -Uz compinit
    compinit
fi

### git-flow
if [ -d "$HOME/.fig/plugins/git-flow" ]; then

    PATH=$PATH:"$HOME/.fig/plugins/git-flow"
fi

### git-flow-completion
if [ -d "$HOME/.fig/plugins/git-flow-completion" ]; then

    source "$HOME/.fig/plugins/git-flow-completion/git-flow-completion.plugin.zsh"
    autoload -Uz compinit
    compinit
fi

### zsh-syntax-highlighting
if [ -d "$HOME/.fig/plugins/zsh-syntax-highlighting" ]; then

    source "$HOME/.fig/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi
