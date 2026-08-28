// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DAO, IDAO} from "@aragon/osx/core/dao/DAO.sol";
import {DAOFactory} from "@aragon/osx/framework/dao/DAOFactory.sol";
import {PermissionManager} from "@aragon/osx/core/permission/PermissionManager.sol";
import {Action} from "@aragon/osx-commons-contracts/src/executors/IExecutor.sol";
import {IPlugin} from "@aragon/osx-commons-contracts/src/plugin/IPlugin.sol";
import {ProxyLib} from "@aragon/osx-commons-contracts/src/utils/deployment/ProxyLib.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";

import {TokenVoting} from "../src/TokenVoting.sol";
import {IMajorityVoting} from "../src/base/IMajorityVoting.sol";
import {GovernanceERC20} from "../src/erc20/GovernanceERC20.sol";
import {VotingPowerCondition} from "../src/condition/VotingPowerCondition.sol";

/// @notice Bundles the parameters needed to deploy and wire up a `TokenVoting` plugin instance.
/// @dev When `existingToken == address(0)`, a new GovernanceERC20 is minted entirely to the
///     deploying account. For a custom initial distribution, mint a token yourself first and
///     pass its address as `existingToken` instead.
struct InstallParams {
    IMajorityVoting.VotingSettings votingSettings;
    address existingToken;
    string tokenName;
    string tokenSymbol;
    bool selfDelegateOnMint;
    IPlugin.TargetConfig targetConfig; // target == address(0) resolves to the DAO itself
    uint256 minApprovals;
    bytes pluginMetadata;
}

/**
 * Installs the TokenVoting plugin onto a DAO by deploying and initializing it directly
 * (no PluginSetupProcessor/PluginRepo involved) and wiring up the permissions
 *
 * Two ways to use it:
 * - Create a brand new DAO via Aragon's `DAOFactory` and install onto it (`createDaoAndInstall`).
 * - Install onto an already-deployed DAO (`installOnExistingDao`) — this requires the caller to
 *   already hold `EXECUTE_PERMISSION_ID` on that DAO (e.g. it was just created by this same script,
 *   or the DAO grants it to an admin/operator). Installing into an existing, fully decentralized DAO
 *   normally requires a governance proposal instead — out of scope here.
 */
contract InstallTokenVotingScript is Script {
    using stdJson for string;
    using ProxyLib for address;

    address private constant ANY_ADDR = address(type(uint160).max);

    address deployer;

    // Artifacts
    DAO public dao;
    TokenVoting public plugin;
    IVotesUpgradeable public token;
    VotingPowerCondition public condition;

    modifier broadcast() {
        uint256 privKey = vm.envUint("DEPLOYER_KEY");
        vm.startBroadcast(privKey);

        deployer = vm.addr(privKey);
        console2.log("General");
        console2.log("- Deploying from:   ", deployer);
        console2.log("- Chain ID:         ", block.chainid);
        console2.log("");

        _;

        vm.stopBroadcast();
    }

    function run() public broadcast {
        address existingDao = vm.envOr("EXISTING_DAO_ADDRESS", address(0));

        if (existingDao == address(0)) {
            _runCreateDaoAndInstall();
        } else {
            _runInstallOnExistingDao(existingDao);
        }

        printDeployment();

        if (!vm.envOr("SIMULATION", false)) {
            writeJsonArtifacts();
        }
    }

    function _runCreateDaoAndInstall() internal {
        DAOFactory daoFactory = DAOFactory(vm.envAddress("DAO_FACTORY_ADDRESS"));
        vm.label(address(daoFactory), "DaoFactory");

        (dao, plugin, token, condition) =
            createDaoAndInstall(daoFactory, readDaoSettings(), readInstallParams());
    }

    function _runInstallOnExistingDao(address _existingDao) internal {
        dao = DAO(payable(_existingDao));
        (plugin, token, condition) = installOnExistingDao(dao, readInstallParams());
    }

    function readDaoSettings() public view returns (DAOFactory.DAOSettings memory daoSettings) {
        daoSettings.trustedForwarder = address(0);
        daoSettings.daoURI = vm.envOr("DAO_URI", string(""));
        daoSettings.subdomain = vm.envOr("DAO_SUBDOMAIN", string(""));
        daoSettings.metadata = bytes(vm.envOr("DAO_METADATA_URI", string("")));
    }

    /// @notice Creates a new DAO via `DAOFactory` (with no plugins installed by the factory itself)
    ///     and directly deploys and wires up the `TokenVoting` plugin on it.
    function createDaoAndInstall(
        DAOFactory _daoFactory,
        DAOFactory.DAOSettings memory _daoSettings,
        InstallParams memory _params
    ) public returns (DAO dao_, TokenVoting plugin_, IVotesUpgradeable token_, VotingPowerCondition condition_) {
        (dao_,) = _daoFactory.createDao(_daoSettings, new DAOFactory.PluginSettings[](0));
        (plugin_, token_, condition_) = installOnExistingDao(dao_, _params);
    }

    /// @notice Deploys and wires up the `TokenVoting` plugin on an already-deployed DAO.
    /// @dev The caller must already hold `EXECUTE_PERMISSION_ID` on `_dao`.
    function installOnExistingDao(DAO _dao, InstallParams memory _params)
        public
        returns (TokenVoting plugin_, IVotesUpgradeable token_, VotingPowerCondition condition_)
    {
        bool mintedNewToken = _params.existingToken == address(0);
        token_ = _resolveToken(_dao, _params, mintedNewToken);
        plugin_ = _deployPlugin(_dao, _params, token_);
        condition_ = new VotingPowerCondition(address(plugin_));
        vm.label(address(condition_), "VotingPowerCondition");

        Action[] memory actions = _buildPermissionActions(_dao, plugin_, token_, condition_, mintedNewToken);
        _dao.execute(bytes32(0), actions, 0);
    }

    function _resolveToken(DAO _dao, InstallParams memory _params, bool _mintedNewToken)
        internal
        returns (IVotesUpgradeable token_)
    {
        if (!_mintedNewToken) {
            return IVotesUpgradeable(_params.existingToken);
        }

        address[] memory holders = new address[](1);
        holders[0] = deployer == address(0) ? msg.sender : deployer;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 1000 ether;

        token_ = new GovernanceERC20(
            IDAO(address(_dao)),
            _params.tokenName,
            _params.tokenSymbol,
            GovernanceERC20.MintSettings(holders, balances, _params.selfDelegateOnMint)
        );
        vm.label(address(token_), "Token");
    }

    /// @dev Deploys the plugin as a minimal proxy against a fresh implementation
    function _deployPlugin(DAO _dao, InstallParams memory _params, IVotesUpgradeable _token)
        internal
        returns (TokenVoting plugin_)
    {
        IPlugin.TargetConfig memory targetConfig = _params.targetConfig;
        if (targetConfig.target == address(0)) {
            targetConfig.target = address(_dao);
        }

        address tokenVotingBase = address(new TokenVoting());
        plugin_ = TokenVoting(
            tokenVotingBase.deployMinimalProxy(
                abi.encodeCall(
                    TokenVoting.initialize,
                    (
                        IDAO(address(_dao)),
                        _params.votingSettings,
                        _token,
                        targetConfig,
                        _params.minApprovals,
                        _params.pluginMetadata
                    )
                )
            )
        );
        vm.label(address(plugin_), "TokenVoting");
    }

    function _buildPermissionActions(
        DAO _dao,
        TokenVoting _plugin,
        IVotesUpgradeable _token,
        VotingPowerCondition _condition,
        bool _mintedNewToken
    ) internal view returns (Action[] memory actions) {
        actions = new Action[](_mintedNewToken ? 7 : 6);

        actions[0] = _grantAction(_dao, address(_plugin), address(_dao), _plugin.UPDATE_VOTING_SETTINGS_PERMISSION_ID());
        actions[1] = _grantAction(_dao, address(_dao), address(_plugin), _dao.EXECUTE_PERMISSION_ID());
        actions[2] =
            _grantWithConditionAction(_dao, address(_plugin), ANY_ADDR, _plugin.CREATE_PROPOSAL_PERMISSION_ID(), _condition);
        actions[3] = _grantAction(_dao, address(_plugin), address(_dao), _plugin.SET_TARGET_CONFIG_PERMISSION_ID());
        actions[4] = _grantAction(_dao, address(_plugin), address(_dao), _plugin.SET_METADATA_PERMISSION_ID());
        actions[5] = _grantAction(_dao, address(_plugin), ANY_ADDR, _plugin.EXECUTE_PROPOSAL_PERMISSION_ID());

        if (_mintedNewToken) {
            actions[6] =
                _grantAction(_dao, address(_token), address(_dao), GovernanceERC20(address(_token)).MINT_PERMISSION_ID());
        }
    }

    function _grantAction(DAO _dao, address _where, address _who, bytes32 _permissionId)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            to: address(_dao),
            value: 0,
            data: abi.encodeCall(
                PermissionManager.grant,
                (_where, _who, _permissionId)
            )
        });
    }

    function _grantWithConditionAction(
        DAO _dao,
        address _where,
        address _who,
        bytes32 _permissionId,
        VotingPowerCondition _condition
    ) internal pure returns (Action memory) {
        return Action({
            to: address(_dao),
            value: 0,
            data: abi.encodeCall(
                PermissionManager.grantWithCondition,
                (_where, _who, _permissionId, _condition)
            )
        });
    }

    function readInstallParams() public view returns (InstallParams memory params) {
        _readTokenSettings(params);
        _readMiscSettings(params);
        _readVotingSettings(params);
    }

    function _readTokenSettings(InstallParams memory params) internal view {
        params.existingToken = vm.envOr("TOKEN_ADDRESS", address(0));
        params.tokenName = vm.envOr("TOKEN_NAME", string("Governance Token"));
        params.tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("GOV"));
        params.selfDelegateOnMint = vm.envOr("SELF_DELEGATE_ON_MINT", true);
    }

    function _readMiscSettings(InstallParams memory params) internal view {
        params.targetConfig = IPlugin.TargetConfig({
            target: vm.envOr("TARGET_ADDRESS", address(0)),
            operation: IPlugin.Operation(vm.envOr("TARGET_OPERATION", uint256(0)))
        });
        params.minApprovals = vm.envOr("MIN_APPROVALS", uint256(0));
        params.pluginMetadata = bytes(vm.envOr("PLUGIN_METADATA_URI", string("")));
    }

    function _readVotingSettings(InstallParams memory params) internal view {
        params.votingSettings.votingMode = IMajorityVoting.VotingMode(vm.envOr("VOTING_MODE", uint256(0)));
        params.votingSettings.supportThreshold = uint32(vm.envOr("SUPPORT_THRESHOLD", uint256(500_000)));
        params.votingSettings.minParticipation = uint32(vm.envOr("MIN_PARTICIPATION", uint256(100_000)));
        params.votingSettings.minDuration = uint64(vm.envOr("MIN_DURATION", uint256(1 hours)));
        params.votingSettings.minProposerVotingPower = vm.envOr("MIN_PROPOSER_VOTING_POWER", uint256(0));
    }

    function printDeployment() public view {
        console2.log("TokenVoting plugin installed:");
        console2.log("- DAO:                       ", address(dao));
        console2.log("- TokenVoting plugin:        ", address(plugin));
        console2.log("- Token:                     ", address(token));
        console2.log("- VotingPowerCondition:      ", address(condition));
        console2.log("");
    }

    function writeJsonArtifacts() internal {
        string memory artifacts = "output";
        artifacts.serialize("dao", address(dao));
        artifacts.serialize("plugin", address(plugin));
        artifacts.serialize("token", address(token));
        artifacts = artifacts.serialize("condition", address(condition));

        string memory networkName = vm.envOr("NETWORK_NAME", string("unknown"));
        string memory filePath = string.concat(
            vm.projectRoot(), "/artifacts/install-", networkName, "-", vm.toString(block.timestamp), ".json"
        );
        artifacts.write(filePath);

        console2.log("Deployment artifacts written to", filePath);
    }
}
