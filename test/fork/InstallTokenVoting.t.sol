// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DAO, IDAO} from "@aragon/osx/core/dao/DAO.sol";
import {DAOFactory} from "@aragon/osx/framework/dao/DAOFactory.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {ForkTestBase} from "../lib/ForkTestBase.sol";

import {InstallTokenVotingScript, InstallParams} from "../../script/InstallTokenVoting.s.sol";
import {TokenVoting} from "../../src/TokenVoting.sol";
import {IMajorityVoting} from "../../src/base/IMajorityVoting.sol";
import {GovernanceERC20} from "../../src/erc20/GovernanceERC20.sol";
import {VotingPowerCondition} from "../../src/condition/VotingPowerCondition.sol";

/// @dev Exercises InstallTokenVotingScript against a real OSx deployment (DAOFactory) on a fork,
///     covering both the new-DAO and existing-DAO install paths plus a full proposal lifecycle.
contract InstallTokenVotingTest is ForkTestBase {
    InstallTokenVotingScript internal script;

    function setUp() public {
        script = new InstallTokenVotingScript();
    }

    function test_WhenCreatingANewDaoWithANewToken() external {
        (DAO dao, TokenVoting plugin, IVotesUpgradeable token, VotingPowerCondition condition) =
            script.createDaoAndInstall(daoFactory, _daoSettings(), _defaultParams());

        assertTrue(
            dao.isGranted(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID(), ""),
            "Plugin should be installed"
        );
        assertTrue(
            dao.isGranted(address(plugin), address(0x1234), plugin.CREATE_PROPOSAL_PERMISSION_ID(), ""),
            "Anyone should be able to create proposals (minProposerVotingPower == 0)"
        );
        assertNotEq(address(token), address(0), "A new token should have been minted");
        assertTrue(plugin.isMember(address(this)), "Deployer should hold the newly minted token");
        assertNotEq(address(condition), address(0));
    }

    function test_WhenCreatingANewDaoWithAnExistingToken() external {
        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;
        uint256[] memory balances = new uint256[](2);
        balances[0] = 100 ether;
        balances[1] = 50 ether;

        GovernanceERC20 existingToken = new GovernanceERC20(
            IDAO(address(0)),
            "Existing Token",
            "EXIST",
            GovernanceERC20.MintSettings(holders, balances, true)
        );

        InstallParams memory params = _defaultParams();
        params.existingToken = address(existingToken);

        (DAO dao, TokenVoting plugin, IVotesUpgradeable token,) =
            script.createDaoAndInstall(daoFactory, _daoSettings(), params);

        assertTrue(
            dao.isGranted(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID(), ""),
            "Plugin should be installed"
        );
        assertEq(address(token), address(existingToken), "The plugin should use the provided token");
        assertTrue(plugin.isMember(alice), "Alice should be a member");
        assertTrue(plugin.isMember(bob), "Bob should be a member");
        assertFalse(plugin.isMember(carol), "Carol should not be a member");
    }

    function test_WhenInstallingOnAnExistingDao() external {
        // Simulates a DAO that already exists and whose operator (this test contract) already
        // holds EXECUTE_PERMISSION_ID on it — the documented precondition for this install path.
        DAO dao = build();
        dao.grant(address(dao), address(script), dao.EXECUTE_PERMISSION_ID());

        (TokenVoting plugin, IVotesUpgradeable token, VotingPowerCondition condition) =
            script.installOnExistingDao(dao, _defaultParams());

        assertTrue(
            dao.isGranted(address(dao), address(plugin), dao.EXECUTE_PERMISSION_ID(), ""),
            "Plugin should be installed"
        );
        assertNotEq(address(token), address(0));
        assertNotEq(address(condition), address(0));
    }

    /// @dev Full create -> vote -> execute cycle through a freshly installed plugin, proving the
    ///     install actually produces a working governance setup and not just correctly-wired permissions.
    function test_FullProposalLifecycle() external {
        (DAO dao, TokenVoting plugin,,) =
            script.createDaoAndInstall(daoFactory, _daoSettings(), _defaultParams());

        // Move past the token mint's checkpoint so the proposal's voting-power snapshot sees it.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        assertTrue(plugin.isMember(address(this)), "Deployer should hold voting power");

        Action[] memory actions = new Action[](1);
        actions[0] = Action({
            to: address(dao),
            value: 0,
            data: abi.encodeCall(DAO.setMetadata, (bytes("e2e-test")))
        });

        uint256 proposalId =
            plugin.createProposal("", actions, 0, 0, 0, IMajorityVoting.VoteOption.Yes, false);

        (bool openBefore, bool executedBefore,,,,,) = plugin.getProposal(proposalId);
        assertTrue(openBefore, "Proposal should be open right after creation");
        assertFalse(executedBefore, "Proposal should not be executed yet");

        vm.warp(block.timestamp + 1 hours + 1);

        assertTrue(
            plugin.canExecute(proposalId),
            "Proposal should be executable after reaching quorum and ending"
        );

        plugin.execute(proposalId);

        (, bool executedAfter,,,,,) = plugin.getProposal(proposalId);
        assertTrue(executedAfter, "Proposal should have executed");
    }

    function _daoSettings() internal pure returns (DAOFactory.DAOSettings memory) {
        return DAOFactory.DAOSettings({
            trustedForwarder: address(0),
            daoURI: "http://host/",
            subdomain: "",
            metadata: ""
        });
    }

    function _defaultParams() internal pure returns (InstallParams memory params) {
        params.votingSettings = IMajorityVoting.VotingSettings({
            votingMode: IMajorityVoting.VotingMode.Standard,
            supportThreshold: 500_000,
            minParticipation: 100_000,
            minDuration: 1 hours,
            minProposerVotingPower: 0
        });

        params.tokenName = "Test Token";
        params.tokenSymbol = "TST";
        params.selfDelegateOnMint = true;
        params.targetConfig = IPlugin.TargetConfig({
            target: address(0),
            operation: IPlugin.Operation.Call
        });
    }
}
