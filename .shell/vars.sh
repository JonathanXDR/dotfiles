#!/bin/bash

if [ -f .env ]; then
  set -o allexport
  source .env
  set +o allexport
fi

export BUN_INSTALL="${HOME}/.bun"
export NVM_DIR="${HOME}/.nvm"
export EDITOR="nano"
export RESOLF='/etc/resolv.conf'

export PATH="${BUN_INSTALL}/bin:${PATH}"
export PATH="${PATH}:${HOME}/.rvm/bin"
export PATH="${HOME}/.console-ninja/.bin:${PATH}"
export PATH="/Library/Frameworks/Python.framework/Versions/3.12/bin:${PATH}"
export PATH="${PATH}:/Users/$USER/Library/Application Support/JetBrains/Toolbox/scripts"
