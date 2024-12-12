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
  local exclude_pattern="$3"

  if [[ -n "$exclude_pattern" ]]; then
    git diff --name-only "$source_branch...$target_branch" -- ":!$exclude_pattern" | while read -r file; do
      echo -e "\n$file:\n"
      git show "$target_branch:$file"
    done | pbcopy
  else
    git diff --name-only "$source_branch...$target_branch" | while read -r file; do
      echo -e "\n$file:\n"
      git show "$target_branch:$file"
    done | pbcopy
  fi

  echo "Diff output copied to clipboard."
}

git:history() {
  editor="code"
  editor_args=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --editor)
      shift
      if [ $# -eq 0 ]; then
        printf 'Error: --editor requires an argument.\n' >&2
        return 1
      fi
      editor="$1"
      shift
      ;;
    --)
      shift
      editor_args="$*"
      break
      ;;
    *)
      printf 'Usage: git:history [--editor <editor>] [-- <editor_args>]\n' >&2
      return 1
      ;;
    esac
  done

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'Error: Not a git repository.\n' >&2
    return 1
  fi

  tmpfile=$(mktemp -t git-history-XXXXXX)
  git log --reverse --pretty=medium >"$tmpfile"

  if ! command -v "$editor" >/dev/null 2>&1; then
    printf 'Error: Editor "%s" not found.\n' "$editor" >&2
    rm -f "$tmpfile"
    return 1
  fi

  if [ -z "$editor_args" ]; then
    case "$editor" in
    code | idea)
      editor_args="--wait"
      ;;
    esac
  fi

  if [ -n "$editor_args" ]; then
    $editor "$editor_args" "$tmpfile" || {
      printf 'Error: Editor exited with an error.\n' >&2
      rm -f "$tmpfile"
      return 1
    }
  else
    $editor "$tmpfile" || {
      printf 'Error: Editor exited with an error.\n' >&2
      rm -f "$tmpfile"
      return 1
    }
  fi

  printf 'Are you sure you want to rewrite the entire git history? (Yes/No): '
  read confirmation
  case "$confirmation" in
  Yes | yes) ;;
  *)
    printf 'Aborted by user.\n'
    rm -f "$tmpfile"
    return 1
    ;;
  esac

  commits_env=""
  authors_env=""
  emails_env=""
  dates_env=""
  messages_env=""

  commit_hash=""
  author=""
  email=""
  date=""
  message=""
  in_message=0
  first_message_line=1

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    commit\ *)
      if [ -n "$commit_hash" ]; then
        commits_env="${commits_env}${commits_env:+}$commit_hash"
        authors_env="${authors_env}${authors_env:+}$author"
        emails_env="${emails_env}${emails_env:+}$email"
        dates_env="${dates_env}${dates_env:+}$date"
        messages_env="${messages_env}${messages_env:+}$message"
      fi
      commit_hash=$(printf '%s' "$line" | sed 's/^commit //')
      author=""
      email=""
      date=""
      message=""
      in_message=0
      first_message_line=1
      ;;
    Merge:\ *) ;;
    Author:\ *)
      author_line=$(printf '%s' "$line" | sed 's/^Author: //')
      author=$(printf '%s' "$author_line" | sed 's/ <.*//')
      email=$(printf '%s' "$author_line" | sed 's/^.*<//; s/>$//')
      ;;
    Date:\ *)
      date=$(printf '%s' "$line" | sed 's/^Date: //; s/^ *//; s/ *$//')
      ;;
    "")
      if [ $in_message -eq 1 ]; then
        message="$message
"
      else
        in_message=1
        first_message_line=1
      fi
      ;;
    *)
      if [ $in_message -eq 1 ]; then
        trimmed=$(printf '%s' "$line" | sed 's/^    //')
        if [ $first_message_line -eq 1 ]; then
          message="$message$trimmed"
          first_message_line=0
        else
          message="$message $trimmed"
        fi
      fi
      ;;
    esac
  done <"$tmpfile"

  if [ -n "$commit_hash" ]; then
    commits_env="${commits_env}${commits_env:+}$commit_hash"
    authors_env="${authors_env}${authors_env:+}$author"
    emails_env="${emails_env}${emails_env:+}$email"
    dates_env="${dates_env}${dates_env:+}$date"
    messages_env="${messages_env}${messages_env:+}$message"
  fi

  rm -f "$tmpfile"
  export commits_env authors_env emails_env dates_env messages_env

  FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
    --env-filter '
    idx=$(printf "%s\n" "$commits_env" | awk -v c="$GIT_COMMIT" "BEGIN{i=0}{if(\$0==c){print i;exit}i++}")
    if [ -n "$idx" ]; then
      line_number=$(expr "$idx" + 1)
      a=$(printf "%s\n" "$authors_env" | sed -n "${line_number}p")
      e=$(printf "%s\n" "$emails_env" | sed -n "${line_number}p")
      d=$(printf "%s\n" "$dates_env"  | sed -n "${line_number}p")

      if [ -n "$a" ]; then
        GIT_AUTHOR_NAME="$a"
        GIT_AUTHOR_EMAIL="$e"
        GIT_AUTHOR_DATE="$d"
        GIT_COMMITTER_NAME="$a"
        GIT_COMMITTER_EMAIL="$e"
        GIT_COMMITTER_DATE="$d"
        export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
        export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
      fi
    fi
  ' \
    --msg-filter '
  idx=$(printf "%s\n" "$commits_env" | awk -v c="$GIT_COMMIT" "BEGIN{i=0}{if(\$0==c){print i;exit}i++}")
  if [ -n "$idx" ]; then
    line_number=$(expr "$idx" + 1)
    m=$(printf "%s\n" "$messages_env" | sed -n "${line_number}p")
    if [ -n "$m" ]; then
      printf "%s\n" "$m"
    else
      cat
    fi
  else
    cat
  fi
  ' \
    -- --all || {
    printf 'Error: Failed to rewrite Git history.\n' >&2
    return 1
  }

  printf 'Git history has been rewritten successfully.\n'
  printf 'Note: If you have already pushed this branch, you will need to force push:\n'
  printf 'git push --force-with-lease\n'
}
