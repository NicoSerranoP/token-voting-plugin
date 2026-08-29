// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/* solhint-disable max-line-length */
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {
    IERC721MetadataUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/IERC721MetadataUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721VotesUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC6372Upgradeable} from "@openzeppelin/contracts-upgradeable/interfaces/IERC6372Upgradeable.sol";

import {
    DaoAuthorizableUpgradeable
} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizableUpgradeable.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IERC721MintableUpgradeable} from "./IERC721MintableUpgradeable.sol";

/* solhint-enable max-line-length */

/// @title GovernanceERC721
/// @author NicoSerranoP (fork of Aragon X)
/// @notice An [OpenZeppelin `Votes`](https://docs.openzeppelin.com/contracts/4.x/api/governance#Votes)
///     compatible [ERC-721](https://eips.ethereum.org/EIPS/eip-721) token, used for voting and managed by a DAO.
///     Each token counts as exactly one unit of voting power. Tokens can be transferred by their holder
///     (`transferFrom` / `safeTransferFrom`) or force-transferred by whoever holds the
///     `TRANSFER_PERMISSION_ID` permission (typically the managing DAO).
/// @dev Voting power is only counted once a token has been delegated. To keep every minted token effective
///     without extra user action, the contract self-delegates any receiver that has no delegate yet
///     (on mint and on transfer). Holders can override this at any time by calling `delegate`.
/// @custom:security-contact sirt@aragon.org
contract GovernanceERC721 is
    IERC721MintableUpgradeable,
    Initializable,
    ERC165Upgradeable,
    ERC721VotesUpgradeable,
    DaoAuthorizableUpgradeable
{
    /// @notice The permission identifier to mint new tokens.
    bytes32 public constant MINT_PERMISSION_ID = keccak256("MINT_PERMISSION");

    /// @notice The permission identifier to burn existing tokens.
    bytes32 public constant BURN_PERMISSION_ID = keccak256("BURN_PERMISSION");

    /// @notice The permission identifier to force-transfer a token regardless of holder approval.
    bytes32 public constant TRANSFER_PERMISSION_ID = keccak256("TRANSFER_PERMISSION");

    /// @notice The identifier that will be assigned to the next minted token. First token id is 1.
    uint256 private nextTokenId;

    /// @notice The settings for the initial mint of the token.
    /// @param receivers The receivers of the tokens. On initialization only. List an address `n` times
    ///     to grant it `n` tokens (i.e. `n` votes).
    struct MintSettings {
        address[] receivers;
    }

    /// @notice Emitted when a token is force-transferred through `adminTransfer`.
    /// @param from The previous holder of the token.
    /// @param to The new holder of the token.
    /// @param tokenId The identifier of the transferred token.
    event AdminTransfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @notice Calls the initialize function.
    /// @param _dao The managing DAO.
    /// @param _name The name of the [ERC-721](https://eips.ethereum.org/EIPS/eip-721) governance token.
    /// @param _symbol The symbol of the [ERC-721](https://eips.ethereum.org/EIPS/eip-721) governance token.
    /// @param _mintSettings The token mint settings struct containing the `receivers`.
    constructor(IDAO _dao, string memory _name, string memory _symbol, MintSettings memory _mintSettings) {
        initialize(_dao, _name, _symbol, _mintSettings);
    }

    /// @notice Initializes the contract and mints one token per entry in `_mintSettings.receivers`.
    /// @param _dao The managing DAO.
    /// @param _name The name of the [ERC-721](https://eips.ethereum.org/EIPS/eip-721) governance token.
    /// @param _symbol The symbol of the [ERC-721](https://eips.ethereum.org/EIPS/eip-721) governance token.
    /// @param _mintSettings The token mint settings struct containing the `receivers`.
    function initialize(IDAO _dao, string memory _name, string memory _symbol, MintSettings memory _mintSettings)
        public
        initializer
    {
        __ERC721_init(_name, _symbol);
        // `ERC721Votes` relies on `EIP712` for `delegateBySig`, so it must be initialized explicitly.
        __EIP712_init(_name, "1");
        __DaoAuthorizableUpgradeable_init(_dao);

        for (uint256 i; i < _mintSettings.receivers.length;) {
            _mintTo(_mintSettings.receivers[i]);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Checks if this or the parent contract supports an interface by its ID.
    /// @param _interfaceId The ID of the interface.
    /// @return Returns `true` if the interface is supported.
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        virtual
        override(ERC165Upgradeable, ERC721Upgradeable)
        returns (bool)
    {
        return _interfaceId == type(IERC721Upgradeable).interfaceId
            || _interfaceId == type(IERC721MetadataUpgradeable).interfaceId
            || _interfaceId == type(IVotesUpgradeable).interfaceId
            || _interfaceId == type(IERC6372Upgradeable).interfaceId
            || _interfaceId == type(IERC721MintableUpgradeable).interfaceId || super.supportsInterface(_interfaceId);
    }

    /// @inheritdoc IERC721MintableUpgradeable
    /// @dev Requires the `MINT_PERMISSION_ID` permission.
    function mint(address _to) external virtual override auth(MINT_PERMISSION_ID) returns (uint256 tokenId) {
        return _mintTo(_to);
    }

    /// @notice Burns an existing token, permanently removing its voting power.
    /// @dev Requires the `BURN_PERMISSION_ID` permission.
    /// @param _tokenId The identifier of the token to burn.
    function burn(uint256 _tokenId) external virtual auth(BURN_PERMISSION_ID) {
        _burn(_tokenId);
    }

    /// @notice Force-transfers a token from its current holder to `_to`, bypassing holder approval.
    /// @dev Requires the `TRANSFER_PERMISSION_ID` permission. Holders transfer their own tokens with the
    ///     standard `transferFrom` / `safeTransferFrom` functions instead.
    /// @param _from The current holder of the token.
    /// @param _to The address receiving the token.
    /// @param _tokenId The identifier of the token to transfer.
    function adminTransfer(address _from, address _to, uint256 _tokenId) external virtual auth(TRANSFER_PERMISSION_ID) {
        _transfer(_from, _to, _tokenId);
        emit AdminTransfer({from: _from, to: _to, tokenId: _tokenId});
    }

    /// @notice Mints the next sequential token id to `_to`.
    /// @param _to The address receiving the token.
    /// @return tokenId The identifier of the freshly minted token.
    function _mintTo(address _to) internal virtual returns (uint256 tokenId) {
        unchecked {
            tokenId = ++nextTokenId;
        }
        _mint(_to, tokenId);
    }

    /// @inheritdoc ERC721VotesUpgradeable
    /// @dev Moves the voting units and, if the receiver has no delegate yet, self-delegates so the token
    ///     immediately counts. See https://forum.openzeppelin.com/t/self-delegation-in-erc20votes/17501/12
    function _afterTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize)
        internal
        virtual
        override(ERC721VotesUpgradeable)
    {
        super._afterTokenTransfer(from, to, firstTokenId, batchSize);

        // Automatically turn on delegation on mint/transfer if not delegating to anyone yet.
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }
}
