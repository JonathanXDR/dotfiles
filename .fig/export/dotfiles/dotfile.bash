### zsh-completions is not supported by bash
### git-flow
if [ -d "$HOME/.fig/plugins/git-flow" ]; then

    PATH=$PATH:"$HOME/.fig/plugins/git-flow"
fi

### git-flow-completion
if [ -d "$HOME/.fig/plugins/git-flow-completion" ]; then

    source "$HOME/.fig/plugins/git-flow-completion/git-flow-completion.bash"
fi

### zsh-syntax-highlighting is not supported by bash
