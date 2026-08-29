// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

/// @title IERC721MintableUpgradeable
/// @notice Interface to allow minting of [ERC-721](https://eips.ethereum.org/EIPS/eip-721) tokens.
/// @custom:security-contact sirt@aragon.org
interface IERC721MintableUpgradeable {
    /// @notice Mints a single [ERC-721](https://eips.ethereum.org/EIPS/eip-721) token for a receiving address.
    /// @param _to The receiving address.
    /// @return tokenId The identifier of the freshly minted token.
    function mint(address _to) external returns (uint256 tokenId);
}
