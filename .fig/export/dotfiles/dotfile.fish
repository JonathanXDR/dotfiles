### zsh-completions is not supported by fish
### git-flow
if test -d "$HOME/.fig/plugins/git-flow"

set PATH "$HOME/.fig/plugins/git-flow" $PATH
end

### git-flow-completion
if test -d "$HOME/.fig/plugins/git-flow-completion"

source "$HOME/.fig/plugins/git-flow-completion/git.fish"
end

### zsh-syntax-highlighting is not supported by fish