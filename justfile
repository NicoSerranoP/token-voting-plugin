default: help
import 'lib/just-foundry/justfile'

# The deploy script run by `just deploy` / `just predeploy`.
DEPLOY_SCRIPT := "script/InstallNFTVoting.s.sol:InstallNFTVotingScript"

# Fetch submodules, scaffold .env and select the network (default: mainnet)
[group('setup')]
init network="mainnet":
    #!/usr/bin/env bash
    set -euo pipefail
    git submodule update --init --recursive
    if [ ! -f .env ] && [ -f .env.example ]; then
        cp .env.example .env
        echo "Created .env from .env.example — edit it with your settings."
    fi
    if ! command -v forge &>/dev/null; then
        echo "Error: Foundry is not installed. Run 'just setup' to install it."
        exit 1
    fi
    just switch {{ network }}
