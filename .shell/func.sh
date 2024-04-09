cmd:exists() {
  [[ -z "$1" ]] && echo "No argument supplied" && exit 1
  command -v "$1" &> /dev/null
}

RESOLF='/etc/resolv.conf'
dns:change() {
  if (( $# < 1 )) ; then
    return 1;
  fi

  local nameservers=("${(@s/,/)1}")

  sudo truncate -s 0 "${RESOLF}"
  for nameServerIP in ${nameservers[@]}; do
    echo "nameserver ${nameServerIP}" | sudo tee -a "${RESOLF}" > /dev/null
  done
}

wsl:change-dns() {
  sudo chattr -i "${RESOLF}"
  dns:change "${1}"
  sudo chattr +i "${RESOLF}"
}

wsl:set-display() {
  local ipconfig="/mnt/c/Windows/System32/ipconfig.exe"
  local grepip=("grep" "-oP" '(?<=IPv4 Address(?:\.\s){11}:\s)((?:\d+\.){3}\d+)')

  if [[ ! -d "/mnt/c/Windows" ]]; then
    return
  fi

  local display=$("${ipconfig}" | grep -A 3 "${ENTERPRISE_DOMAIN}" | "${grepip[@]}")
  if [[ -n "${display}" ]]; then
    export DISPLAY="${display}:0.0"
    return
  fi
  export DISPLAY=$("${ipconfig}" | grep -A 5 "vEthernet (WSL)" | "${grepip[@]}"):0.0
}

proxy:compose-addr() {
  if (( $# != 3 )) ; then
    return 1;
  fi

  local proxyProtocol="${1}"
  local proxyHost="${2}"
  local proxyPort="${3}"

  echo "${proxyProtocol}://${proxyHost}:${proxyPort}"
}

proxy:set() {
  if [[ -z "${PROXY_PROTOCOL}" || -z "${PROXY_HOST}" || -z "${PROXY_PORT}" ]]; then
    source "${HOME}/.shell/vars.sh"
  fi

  local proxyProtocol="${1:-${PROXY_PROTOCOL}}}"
  local proxyHost="${2:-${PROXY_HOST}}}"
  local proxyPort="${3:-${PROXY_PORT}}}"
  local noProxy="${4:-${NOPROXY}}}"
  
  local proxyAddr="$(proxy:compose-addr "${proxyProtocol}" "${proxyHost}" "${proxyPort}")"
  
  export http_proxy="${proxyAddr}"
  export HTTP_PROXY="${proxyAddr}"
  export https_proxy="${proxyAddr}"
  export HTTPS_PROXY="${proxyAddr}"
  export ftp_proxy="${proxyAddr}"
  export FTP_PROXY="${proxyAddr}"
  export all_proxy="${proxyAddr}"
  export ALL_PROXY="${proxyAddr}"
  export PIP_PROXY="${proxyAddr}"
  export no_proxy="${noProxy}"
  export NO_PROXY="${noProxy}"
  export MAVEN_OPTS="-Dhttp.proxyHost=${proxyHost} -Dhttp.proxyPort=${proxyPort} -Dhttps.proxyHost=${proxyHost} -Dhttps.proxyPort=${proxyPort}"

  if [[ -z "${proxyProtocol}" || -z "${proxyHost}" || -z "${proxyPort}" ]]; then
    echo "Syntax: proxy:set proxyProtocol proxyHost proxyPort [noProxy]"
    echo "Or ensure PROXY_PROTOCOL, PROXY_HOST, and PROXY_PORT are set in ${HOME}/.shell/vars.sh"
    return 1
  fi
}

proxy:unset() {
  unset http_proxy
  unset HTTP_PROXY
  unset https_proxy
  unset HTTPS_PROXY
  unset ftp_proxy
  unset FTP_PROXY
  unset all_proxy
  unset ALL_PROXY
  unset PIP_PROXY
  unset no_proxy
  unset NO_PROXY
  unset MAVEN_OPTS
}

proxy:probe() {
  local matchDNS="dns"
  local withDNS="${1}"
  if nc -z -w 3 "${PROXY_HOST}" "${PROXY_PORT}" &> /dev/null; then
    echo "Detected VPN, turning on proxy."
    proxy:set "${PROXY_PROTOCOL}" "${PROXY_HOST}" "${PROXY_PORT}" "${NOPROXY}"
    if [[ "${(L)withDNS}" = "${matchDNS}" ]]; then
      wsl:change-dns "${PROXY_DNS},${NO_PROXY_DNS}"
    fi
  else
    echo "Detected normal network, turning off proxy."
    proxy:unset
    if [[ "${(L)withDNS}" = "${matchDNS}" ]]; then
      wsl:change-dns "${NO_PROXY_DNS},${PROXY_DNS}"
    fi
  fi
}

proxy:aws() {
  local proxyArgs=("${AWS_PROXY_PROTOCOL}" "${AWS_PROXY_HOST}" "${AWS_PROXY_PORT}")
  local proxyAddr="$(proxy:compose-addr ${proxyArgs[@]})"

  if [[ "${http_proxy}" != "${proxyAddr}" ]]; then
    proxy:set ${proxyArgs[@]}
  else
    proxy:unset
  fi
}

#SSH Reagent (http://tychoish.com/post/9-awesome-ssh-tricks/)
ssh:reagent () {
  for agent in /tmp/ssh-*/agent.*; do
    export SSH_AUTH_SOCK=${agent}
      if ssh-add -l 2>&1 > /dev/null; then
        echo Found working SSH Agent:
        ssh-add -l
        return
      fi
  done
  echo Cannot find ssh agent - maybe you should reconnect and forward it?
}

ssh:agent() {
  pgrep -x ssh-agent &> /dev/null && sshReagent &> /dev/null || eval $(ssh-agent) &> /dev/null
}

cluster:change() {
  local clusterName="${1:-${AWS_CLUSTER_NAME}}"
  export AWS_CLUSTER_NAME="${clusterName}"
  aws eks update-kubeconfig --name "${AWS_CLUSTER_NAME}" --region "${AWS_REGION}"
}

docker:cleanup() {
  keywords="$*"

  if [[ -z "${keywords}" ]]; then
    docker stop $(docker ps -a -q)
    docker rm $(docker ps -a -q)
    docker rmi $(docker images -q)
  else
    containers_to_stop=$(docker ps -a --format '{{.ID}} {{.Names}}' | grep -v -E "(${keywords})" | awk '{print $1}')
    docker stop "${containers_to_stop}"
    docker rm "${containers_to_stop}"

    images_to_remove=$(docker images --format '{{.ID}} {{.Repository}}' | grep -v -E "(${keywords})" | awk '{print $1}')
    docker rmi "${images_to_remove}"
  fi
}

dock:reset() {
  defaults delete com.apple.dock
  killall Dock
  sleep 5

  apps=("Arc" "Notion" "Visual Studio Code" "Microsoft Teams (work or school)" "Discord" "GitKraken")

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
  local response

  response=$(nvm install node --latest-npm 2>&1)

  if [[ "${response}" != *"already installed"* ]]; then
    nvm use node
  fi
}

nvmrc:load() {
  local nvmrc_path
  nvmrc_path="$(nvm_find_nvmrc)"

  if [[ -n "${nvmrc_path}" ]]; then
    local nvmrc_node_version
    nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")

    if [[ "${nvmrc_node_version}" = "N/A" ]]; then
      nvm install
    elif [[ "${nvmrc_node_version}" != "$(nvm version)" ]]; then
      nvm use
    fi
  elif [[ -n "$(PWD=${OLDPWD} nvm_find_nvmrc)" ]] && [[ "$(nvm version)" != "$(nvm version default)" ]]; then
    echo "Reverting to nvm default version"
    nvm use default
  fi
}

npm:update() {
  npm i -g npm-check-updates
  ncu -u
  rm -rf node_modules
  rm -f package-lock.json
  npm install
}

git:date() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "This directory is not a Git repository."
    return 1
  fi

  echo "Enter the commit hash (e.g., abcd1234) or press Enter to use the latest commit:"
  read COMMIT_HASH

  if [[ -z "${COMMIT_HASH}" ]]; then
    COMMIT_HASH=$(git rev-parse HEAD)
  fi

  AUTHOR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
  echo "Enter the AUTHOR_DATE (in 'YYYY-MM-DD HH:MM:SS' format) or press Enter to use current date [${AUTHOR_DATE}]:"
  vared -p '' -c AUTHOR_DATE

  COMMITTER_DATE=$(date +"%Y-%m-%d %H:%M:%S")
  echo "Enter the COMMITTER_DATE (in 'YYYY-MM-DD HH:MM:SS' format) or press Enter to use current date [${COMMITTER_DATE}]:"
  vared -p '' -c COMMITTER_DATE

  [[ -z "${AUTHOR_DATE}" ]] && AUTHOR_DATE=$(date +"%Y-%m-%d %H:%M:%S")
  [[ -z "${COMMITTER_DATE}" ]] && COMMITTER_DATE=$(date +"%Y-%m-%d %H:%M:%S")

  if [[ "${COMMIT_HASH}" == $(git rev-parse HEAD) ]]; then
    GIT_AUTHOR_DATE="${AUTHOR_DATE}" GIT_COMMITTER_DATE="${COMMITTER_DATE}" git commit --amend --no-edit --date "${AUTHOR_DATE}"
  else
    FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --env-filter "
      if test \$GIT_COMMIT = '${COMMIT_HASH}'
      then
        export GIT_AUTHOR_DATE='${AUTHOR_DATE}'
        export GIT_COMMITTER_DATE='${COMMITTER_DATE}'
      fi
        " "${COMMIT_HASH}"^..HEAD </dev/null
  fi

  echo "Date changed successfully!"
}