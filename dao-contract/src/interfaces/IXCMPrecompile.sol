// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IXCMPrecompile
/// @notice Interface for the XCM precompile on Polkadot Hub
/// @dev Fixed address: 0x00000000000000000000000000000000000a0000
/// @dev Docs: https://docs.polkadot.com/develop/smart-contracts/precompiles/xcm-precompile/
interface IXCMPrecompile {

    /// @notice Estimate the weight required to execute an XCM message
    /// @dev Always call this before execute() to get the correct weight value
    /// @param message SCALE-encoded XCM message bytes
    /// @return refTime   The reference time component of the weight
    /// @return proofSize The proof size component of the weight
    function weighMessage(bytes calldata message)
        external
        returns (uint64 refTime, uint64 proofSize);

    /// @notice Execute an XCM message locally using the caller's origin
    /// @dev Main entrypoint for cross-chain treasury transfers
    /// @param message SCALE-encoded XCM message bytes
    /// @param weight  refTime weight obtained from weighMessage() for the same message
    function execute(bytes calldata message, uint64 weight) external;

    /// @notice Send an XCM message to a remote destination
    /// @param dest    SCALE-encoded destination multilocation
    /// @param message SCALE-encoded XCM message bytes
    function send(bytes calldata dest, bytes calldata message) external;
}
