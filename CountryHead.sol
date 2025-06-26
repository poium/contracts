
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CountryHead
/// @notice One ERC-721 token per Country (tokenId == countryId). The holder
///         receives the 1 % head fee routed by CountryTokens.
contract CountryHead is ERC721, Ownable {
    // Optional base URI for off-chain metadata
    string private _baseTokenURI;

    /// @param baseURI Initial base URI (can be empty and set later).
    constructor(string memory baseURI) ERC721("Country Head", "HEAD") Ownable(msg.sender) {
        _baseTokenURI = baseURI;
    }

    /* ───────────────── ADMIN ───────────────── */

    /// @notice Mint a head NFT for the given country and assign it to `to`.
    /// @dev `countryId` **must** match the countryId in CountryTokens.
    function mintHead(address to, uint256 countryId) external onlyOwner {
        require(to != address(0), "invalid to");
        _safeMint(to, countryId);
    }

    /// @notice Change the base URI for token metadata.
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
    }

    /* ───────────────── INTERNALS ───────────────── */

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
} 
