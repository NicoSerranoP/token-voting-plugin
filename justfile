default: help
import 'lib/just-foundry/justfile'

# The deploy script run by `just deploy` / `just predeploy`. Pick the flow you need:
DEPLOY_SCRIPT := "script/DeployTokenVoting_1_4.s.sol:DeployTokenVoting_1_4Script"
# DEPLOY_SCRIPT := "script/DeployNewTokenVotingRepo.s.sol:DeployNewTokenVotingRepoScript"

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

# Pin the release & build metadata to IPFS (requires PINATA_JWT)
[group('metadata')]
pin-metadata:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "build-metadata.json  -> $(just ipfs-pin script/metadata/build-metadata.json)"
    echo "release-metadata.json -> $(just ipfs-pin script/metadata/release-metadata.json)"

# Encode & print the calldata to create the upgrade proposal (needs a prior deploy broadcast on the active network)
[group('metadata')]
upgrade-proposal:
    #!/usr/bin/env bash
    set -euo pipefail
    source lib/just-foundry/lib.sh && env_load --verbose
    command -v jq &>/dev/null || { echo "Error: jq is required"; exit 1; }
    if [ "${CHAIN_ID:-}" = "300" ] || [ "${CHAIN_ID:-}" = "324" ]; then
        echo "On ZkSync, set the PluginSetup address passed to EncodeUpgradeProposal.sol manually." >&2
        exit 1
    fi
    SCRIPT_FILE=$(basename "$(echo '{{ DEPLOY_SCRIPT }}' | cut -d: -f1)")
    BROADCAST="broadcast/${SCRIPT_FILE}/${CHAIN_ID}/run-latest.json"
    [ -f "$BROADCAST" ] || { echo "Error: no broadcast at $BROADCAST — run 'just deploy' first." >&2; exit 1; }
    PLUGIN_SETUP=$(jq -r ".transactions[2].contractAddress" "$BROADCAST")
    META=script/metadata/upgrade-proposal-metadata.json
    sed -e "s|___PLUGIN_SETUP___|${PLUGIN_SETUP}|g" \
        -e "s|___PLUGIN_REPO___|${TOKEN_VOTING_PLUGIN_REPO_ADDRESS}|g" \
        -e "s|___RELEASE_METADATA___|${RELEASE_METADATA_URI}|g" \
        -e "s|___BUILD_METADATA___|${BUILD_METADATA_URI}|g" \
        script/metadata/upgrade-proposal-metadata-template.json > "$META"
    PROPOSAL_METADATA_URI=$(bash lib/just-foundry/scripts/ipfs-pin.sh "$META")
    PLUGIN_SETUP="$PLUGIN_SETUP" \
    PROPOSAL_METADATA_URI="$PROPOSAL_METADATA_URI" \
    TIMESTAMP="$(date +%s)" \
        forge script script/EncodeUpgradeProposal.sol -vvv
