#!/usr/bin/env bash

if [ -f "${HOME}"/.env ]; then
  set -o allexport
  source "${HOME}/.env"
  set +o allexport
else
  echo ".env file not found"
fi

export PROXY_PROTOCOL=${PROXY_PROTOCOL:-http}
export PROXY_HOST=${PROXY_HOST:-localhost}
export PROXY_PORT=${PROXY_PORT:-8080}
export NOPROXY=${NOPROXY:-localhost,127.0.0.1}
export AWS_CLUSTER_NAME=${AWS_CLUSTER_NAME:-default-cluster}
export AWS_REGION=${AWS_REGION:-us-west-2}

export NTLM_CREDENTIALS=${NTLM_CREDENTIALS}

export BUN_INSTALL="${HOME}/.bun"
export NVM_DIR="${HOME}/.nvm"
export EDITOR="nano"
export RESOLF='/etc/resolv.conf'

export PATH="${BUN_INSTALL}/bin:${PATH}"
export PATH="${PATH}:${HOME}/.rvm/bin"
export PATH="${HOME}/.console-ninja/.bin:${PATH}"
export PATH="/Library/Frameworks/Python.framework/Versions/3.12/bin:${PATH}"
export PATH="${PATH}:/Users/$USER/Library/Application Support/JetBrains/Toolbox/scripts"
