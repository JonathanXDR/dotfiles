# CodeWhisperer pre block. Keep at the top of this file.
[[ -f "${HOME}/Library/Application Support/codewhisperer/shell/zshrc.pre.zsh" ]] && builtin source "${HOME}/Library/Application Support/codewhisperer/shell/zshrc.pre.zsh"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"                   # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion

# Setting PATH for Python 3.12
# The original version is saved in .zprofile.pysave
PATH="/Library/Frameworks/Python.framework/Versions/3.12/bin:${PATH}"
export PATH

eval "$(pyenv init --path)"
alias python='python3'
autoload -U add-zsh-hook

nvm:update() {
  local response

  response=$(nvm install node --latest-npm 2>&1)

  if [[ "$response" != *"already installed"* ]]; then
    nvm use node
  fi
}

load-nvmrc() {
  local nvmrc_path
  nvmrc_path="$(nvm_find_nvmrc)"

  if [ -n "$nvmrc_path" ]; then
    local nvmrc_node_version
    nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")

    if [ "$nvmrc_node_version" = "N/A" ]; then
      nvm install
    elif [ "$nvmrc_node_version" != "$(nvm version)" ]; then
      nvm use
    fi
  elif [ -n "$(PWD=$OLDPWD nvm_find_nvmrc)" ] && [ "$(nvm version)" != "$(nvm version default)" ]; then
    echo "Reverting to nvm default version"
    nvm use default
  fi
}

add-zsh-hook chpwd load-nvmrc
nvm:update
load-nvmrc

git:date() {
  # Check if the current directory is a Git repository
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "This directory is not a Git repository."
    return 1
  fi

  # Prompt user for the commit hash
  echo "Enter the commit hash (e.g., abcd1234) or press Enter to use the latest commit:"
  read COMMIT_HASH

  # Default to the latest commit on the current branch if input is empty
  if [[ -z "$COMMIT_HASH" ]]; then
    COMMIT_HASH=$(git rev-parse HEAD)
  fi

  # Prompt user for the AUTHOR_DATE with a default value
  AUTHOR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
  echo "Enter the AUTHOR_DATE (in 'YYYY-MM-DD HH:MM:SS' format) or press Enter to use current date [$AUTHOR_DATE]:"
  vared -p '' -c AUTHOR_DATE

  # Prompt user for the COMMITTER_DATE with a default value
  COMMITTER_DATE=$(date +"%Y-%m-%d %H:%M:%S")
  echo "Enter the COMMITTER_DATE (in 'YYYY-MM-DD HH:MM:SS' format) or press Enter to use current date [$COMMITTER_DATE]:"
  vared -p '' -c COMMITTER_DATE

  # If the variables are empty after using `vared`, set them to the current date/time
  [[ -z "$AUTHOR_DATE" ]] && AUTHOR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
  [[ -z "$COMMITTER_DATE" ]] && COMMITTER_DATE=$(date +"%Y-%m-%d %H:%M:%S")

  # Change the commit date using the provided values
  if [[ "$COMMIT_HASH" == $(git rev-parse HEAD) ]]; then
    # Directly amend the latest commit if it's the one selected
    GIT_AUTHOR_DATE="$AUTHOR_DATE" GIT_COMMITTER_DATE="$COMMITTER_DATE" git commit --amend --no-edit --date "$AUTHOR_DATE"
  else
    # Use filter-branch to amend the specific commit and suppress warnings
    FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter "
      if test \$GIT_COMMIT = '$COMMIT_HASH'
      then
        export GIT_AUTHOR_DATE='$AUTHOR_DATE'
        export GIT_COMMITTER_DATE='$COMMITTER_DATE'
      fi
        " $COMMIT_HASH^..HEAD </dev/null
  fi

  echo "Date changed successfully!"
}

docker:cleanup() {
  # Get keywords from user
  keywords="$*"

  if [ -z "$keywords" ]; then
    # Stop all containers
    docker stop $(docker ps -a -q)

    # Remove all containers
    docker rm $(docker ps -a -q)

    # Remove all images
    docker rmi $(docker images -q)
  else
    # Get containers not containing keywords
    containers_to_stop=$(docker ps -a --format '{{.ID}} {{.Names}}' | grep -v -E "($keywords)" | awk '{print $1}')

    # Stop containers not containing keywords
    docker stop $containers_to_stop

    # Remove containers not containing keywords
    docker rm $containers_to_stop

    # Get images not containing keywords
    images_to_remove=$(docker images --format '{{.ID}} {{.Repository}}' | grep -v -E "($keywords)" | awk '{print $1}')

    # Remove images not containing keywords
    docker rmi $images_to_remove
  fi
}

npm:update() {
  npm i -g npm-check-updates
  ncu -u
  rm -rf node_modules
  rm -f package-lock.json
  npm install
}

dock:reset() {
  # Reset the dock
  defaults delete com.apple.dock
  killall Dock

  # Wait for 5 seconds
  sleep 5

  # List of applications to add to the dock
  apps=("Arc" "Notion" "Visual Studio Code" "Microsoft Teams (work or school)" "Discord" "GitKraken")

  # Add each application to the dock
  for app in "${apps[@]}"; do
    defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>/Applications/${app}.app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
  done

  # Apply the specified dock settings
  defaults write com.apple.dock mineffect -string "scale"
  defaults write com.apple.dock minimize-to-application -bool true
  defaults write com.apple.dock launchanim -bool false
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock expose-group-apps -bool true

  # Refresh the dock again to apply settings
  killall Dock
}

# bun completions
[ -s "/Users/jonathan/.bun/_bun" ] && source "/Users/jonathan/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

PATH=~/.console-ninja/.bin:$PATH

# Add RVM to PATH for scripting. Make sure this is the last PATH variable change.
export PATH="$PATH:$HOME/.rvm/bin"


[[ -f "$HOME/fig-export/dotfiles/dotfile.zsh" ]] && builtin source "$HOME/fig-export/dotfiles/dotfile.zsh"

# CodeWhisperer post block. Keep at the bottom of this file.
[[ -f "${HOME}/Library/Application Support/codewhisperer/shell/zshrc.post.zsh" ]] && builtin source "${HOME}/Library/Application Support/codewhisperer/shell/zshrc.post.zsh"
