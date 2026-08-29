// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import {NFTVoting} from "../NFTVoting.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {IPermissionCondition} from "@aragon/osx-commons-contracts/src/permission/condition/IPermissionCondition.sol";
import {PermissionCondition} from "@aragon/osx-commons-contracts/src/permission/condition/PermissionCondition.sol";

/// @title VotingPowerCondition
/// @author NicoSerranoP (fork of Aragon X 2025)
/// @notice Checks if an account's voting power meets the threshold set in an associated `NFTVoting` plugin.
/// @custom:security-contact sirt@aragon.org
contract VotingPowerCondition is PermissionCondition {
    /// @notice The `NFTVoting` plugin used to fetch voting power settings.
    NFTVoting private immutable PLUGIN;

    /// @notice The `IVotesUpgradeable` token interface used to check voting power.
    IVotesUpgradeable private immutable VOTING_TOKEN;

    /// @notice Initializes the contract with the `NFTVoting` plugin address and fetches the associated token.
    /// @param _plugin The address of the `NFTVoting` plugin.
    constructor(address _plugin) {
        PLUGIN = NFTVoting(_plugin);
        VOTING_TOKEN = PLUGIN.getVotingToken();
    }

    /// @inheritdoc IPermissionCondition
    /// @dev The function checks the voting power to ensure `_who` meets the minimum voting threshold defined
    ///      in the `NFTVoting` plugin. Returns `false` if the minimum requirement is unmet.
    function isGranted(address _where, address _who, bytes32 _permissionId, bytes calldata _data)
        public
        view
        override
        returns (bool)
    {
        (_where, _data, _permissionId);

        uint256 minProposerVotingPower_ = PLUGIN.minProposerVotingPower();

        if (minProposerVotingPower_ != 0) {
            uint256 _timepoint;
            if (PLUGIN.tokenIndexedByTimestamp()) {
                _timepoint = block.timestamp - 1;
            } else {
                _timepoint = block.number - 1;
            }

            if (VOTING_TOKEN.getPastVotes(_who, _timepoint) < minProposerVotingPower_) {
                return false;
            }
        }

        return true;
    }
}
