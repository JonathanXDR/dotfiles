#!/usr/bin/env bash

cmd:exists() {
  [[ $# -eq 1 ]] || {
    echo "Usage: cmd:exists <command>" >&2
    return 1
  }
  command -v "$1" &>/dev/null
}

dns:change() {
  if (($# < 2)); then
    echo "Usage: dns:change <network service name> <DNS IPs separated by commas>" >&2
    return 1
  fi

  local network_service="$1"
  IFS=',' read -ra nameservers <<<"$2"

  sudo networksetup -setdnsservers "${network_service}" "Empty" "${nameservers[@]}"
}

proxy:compose-addr() {
  [[ $# -eq 3 ]] || return 1
  printf "%s://%s:%s" "$1" "$2" "$3"
}

proxy:set() {
  local proxy_protocol="${1:-${PROXY_PROTOCOL}}"
  local proxy_host="${2:-${PROXY_HOST}}"
  local proxy_port="${3:-${PROXY_PORT}}"
  local no_proxy="${4:-${NOPROXY}}"

  if [[ -z "${proxy_protocol}" || -z "${proxy_host}" || -z "${proxy_port}" ]]; then
    echo "Usage: proxy:set <protocol> <host> <port> [no_proxy]" >&2
    echo "Or ensure PROXY_PROTOCOL, PROXY_HOST, and PROXY_PORT are set in ${HOME}/.shell/vars.sh" >&2
    return 1
  fi

  local proxy_addr
  proxy_addr="$(proxy:compose-addr "${proxy_protocol}" "${proxy_host}" "${proxy_port}")"

  export http_proxy="${proxy_addr}"
  export https_proxy="${proxy_addr}"
  export ftp_proxy="${proxy_addr}"
  export all_proxy="${proxy_addr}"
  export HTTP_PROXY="${proxy_addr}"
  export HTTPS_PROXY="${proxy_addr}"
  export FTP_PROXY="${proxy_addr}"
  export ALL_PROXY="${proxy_addr}"
  export PIP_PROXY="${proxy_addr}"
  export no_proxy="${no_proxy}"
  export NO_PROXY="${no_proxy}"
  export MAVEN_OPTS="-Dhttp.proxyHost=${proxy_host} -Dhttp.proxyPort=${proxy_port} -Dhttps.proxyHost=${proxy_host} -Dhttps.proxyPort=${proxy_port}"
}

proxy:unset() {
  unset http_proxy https_proxy ftp_proxy all_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY PIP_PROXY no_proxy NO_PROXY MAVEN_OPTS
}

proxy:probe() {
  local with_dns="${1:-}"
  if nc -z -w 3 "${PROXY_HOST}" "${PROXY_PORT}" &>/dev/null; then
    echo "Detected VPN, turning on proxy."
    proxy:set "${PROXY_PROTOCOL}" "${PROXY_HOST}" "${PROXY_PORT}" "${NOPROXY}"
    [[ "${with_dns}" == "dns" ]] && wsl_change_dns "${PROXY_DNS:-},${NO_PROXY_DNS:-}"
  else
    # echo "Detected normal network, turning off proxy."
    proxy:unset
    [[ "${with_dns}" == "dns" ]] && wsl_change_dns "${NO_PROXY_DNS:-},${PROXY_DNS:-}"
  fi
}

proxy:aws() {
  local proxy_args=("${AWS_PROXY_PROTOCOL:-http}" "${AWS_PROXY_HOST:-localhost}" "${AWS_PROXY_PORT:-8080}")
  local proxy_addr
  proxy_addr="$(proxy:compose-addr "${proxy_args[@]}")"

  if [[ "${http_proxy:-}" != "${proxy_addr}" ]]; then
    proxy:set "${proxy_args[@]}"
  else
    proxy:unset
  fi
}

ssh:reagent() {
  for agent in /tmp/ssh-*/agent.*; do
    export SSH_AUTH_SOCK="${agent}"
    if ssh-add -l &>/dev/null; then
      echo "Found working SSH Agent:"
      ssh-add -l
      return 0
    fi
  done
  echo "Cannot find ssh agent - maybe you should reconnect and forward it?"
  return 1
}

ssh:agent() {
  pgrep -x ssh-agent &>/dev/null && ssh:reagent &>/dev/null || eval "$(ssh-agent)" &>/dev/null
}

cluster:change() {
  local cluster_name="${1:-${AWS_CLUSTER_NAME}}"
  export AWS_CLUSTER_NAME="${cluster_name}"
  aws eks update-kubeconfig --name "${AWS_CLUSTER_NAME}" --region "${AWS_REGION}"
}

docker:cleanup() {
  if [[ $# -eq 0 ]]; then
    docker stop "$(docker ps -aq)" 2>/dev/null || true
    docker rm "$(docker ps -aq)" 2>/dev/null || true
    docker rmi "$(docker images -q)" 2>/dev/null || true
  else
    local keywords="$*"
    docker stop "$(docker ps -a --format '{{.ID}} {{.Names}}' | grep -vE "(${keywords})" | awk '{print $1}')" 2>/dev/null || true
    docker rm "$(docker ps -a --format '{{.ID}} {{.Names}}' | grep -vE "(${keywords})" | awk '{print $1}')" 2>/dev/null || true
    docker rmi "$(docker images --format '{{.ID}} {{.Repository}}' | grep -vE "(${keywords})" | awk '{print $1}')" 2>/dev/null || true
  fi
}

dock:reset() {
  defaults delete com.apple.dock
  killall Dock
  sleep 5

  local apps=("Arc" "Notion" "Visual Studio Code" "Microsoft Teams" "Discord" "GitKraken")

  for app in "${apps[@]}"; do
    defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>/Applications/${app}.app</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
  done

  defaults write com.apple.dock mineffect -string "scale"
  defaults write com.apple.dock minimize-to-application -bool true
  defaults write com.apple.dock launchanim -bool false
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock expose-group-apps -bool true

  killall Dock
}

nvm:update() {
  if ! nvm install node --latest-npm 2>&1 | tee /dev/null | grep -q "already installed"; then
    nvm use node
  fi
}

bun:update() {
  bun upgrade &>/dev/null
}

nvmrc:load() {
  local nvmrc_path
  nvmrc_path="$(nvm_find_nvmrc)"

  if [[ -n "${nvmrc_path}" ]]; then
    local nvmrc_node_version
    nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")

    if [[ "${nvmrc_node_version}" == "N/A" ]]; then
      nvm install
    elif [[ "${nvmrc_node_version}" != "$(nvm version)" ]]; then
      nvm use
    fi
  elif [[ -n "$(PWD=${OLDPWD} nvm_find_nvmrc)" ]] && [[ "$(nvm version)" != "$(nvm version default)" ]]; then
    echo "Reverting to nvm default version"
    nvm use default
  fi
}

link:dotfiles() {
  local source_dir="$HOME/Developer/Git/GitHub/Dotfiles/"
  local target_dir="$HOME"
  local -a skip_files=(".DS_Store" ".git" ".gitignore" "LICENSE" "README.md")

  for file in "$source_dir".*; do
    local filename
    filename=$(basename "$file")

    [[ " ${skip_files[*]} " =~ ${filename} ]] && {
      echo "Skipping $filename"
      continue
    }

    local target="$target_dir/$filename"

    if [[ -e "$target" ]]; then
      echo "File or directory $target already exists, skipping..."
    else
      ln -s "$file" "$target"
      echo "Created symlink for $filename"
    fi
  done
}

ncu:update() {
  # npm i -g npm-check-updates
  # npm i -g @antfu/ni
  ncu -u
  rm -rf node_modules
  rm -f yarn.lock package-lock.json pnpm-lock.yaml bun.lockb
  ni
}

git:diff() {
  local source_branch="$1"
  local target_branch="$2"

  git diff --name-only "$source_branch...$target_branch" | while read -r file; do
    echo -e "\n$file:\n"
    git show "$target_branch:$file"
  done | pbcopy

  echo "Diff output copied to clipboard."
}

git:author() {
  [[ $# -eq 4 ]] || {
    echo "Usage: git:author <repo_path> <branch_name> <new_author_name> <new_author_email>" >&2
    return 1
  }

  local repo_path="$1" branch_name="$2" new_author_name="$3" new_author_email="$4"

  [[ -d "$repo_path/.git" ]] || {
    echo "Error: '$repo_path' is not a Git repository." >&2
    return 1
  }

  cd "$repo_path" || {
    echo "Error: Unable to change to directory '$repo_path'." >&2
    return 1
  }

  git rev-parse --verify "$branch_name" >/dev/null 2>&1 || {
    echo "Error: Branch '$branch_name' does not exist." >&2
    return 1
  }

  git filter-branch -f --env-filter "
        GIT_AUTHOR_NAME='$new_author_name'
        GIT_AUTHOR_EMAIL='$new_author_email'
        GIT_COMMITTER_NAME='$new_author_name'
        GIT_COMMITTER_EMAIL='$new_author_email'
        export GIT_AUTHOR_NAME
        export GIT_AUTHOR_EMAIL
        export GIT_COMMITTER_NAME
        export GIT_COMMITTER_EMAIL
    " "$branch_name" || {
    echo "Error: Failed to rewrite Git history." >&2
    return 1
  }

  echo "Git history has been rewritten successfully."
}
