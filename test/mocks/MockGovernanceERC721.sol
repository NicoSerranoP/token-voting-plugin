// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.8;

import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";

import {GovernanceERC721} from "../../src/erc721/GovernanceERC721.sol";

/// @title MockGovernanceERC721
/// @author NicoSerranoP (fork of Aragon X)
/// @notice A test GovernanceERC721 that can be minted and burned by everyone.
/// @dev DO NOT USE IN PRODUCTION!
contract MockGovernanceERC721 is GovernanceERC721 {
    constructor(IDAO _dao, TokenSettings memory _settings)
        GovernanceERC721(_dao, _settings)
    {}

    /// @notice Mints the next sequential token id to `_to` without any permission check.
    function mintTo(address _to) public returns (uint256) {
        return _mintTo(_to);
    }

    /// @notice Burns `_tokenId` without any permission check.
    function burnToken(uint256 _tokenId) public {
        _burn(_tokenId);
    }
}
