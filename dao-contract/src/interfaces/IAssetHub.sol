// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssetHub
/// @notice Interface for Polkadot Asset Hub precompile
/// @dev Precompile address: 0x0000000000000000000000000000000000000806
interface IAssetHub {
    /// @notice Get the balance of a Polkadot native asset for an account
    /// @param assetId The asset ID on Asset Hub
    /// @param who The account to query
    function balanceOf(uint128 assetId, address who) external view returns (uint256);

    /// @notice Transfer a native Polkadot asset
    /// @param assetId The asset ID
    /// @param to Recipient address
    /// @param amount Amount to transfer
    function transfer(uint128 assetId, address to, uint256 amount) external returns (bool);

    /// @notice Get asset metadata
    /// @param assetId The asset ID
    function assetMetadata(uint128 assetId)
        external
        view
        returns (string memory name, string memory symbol, uint8 decimals);
}
