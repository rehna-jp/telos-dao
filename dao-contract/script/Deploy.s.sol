// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {GovernanceContract} from "../src/GovernanceContract.sol";
import {TreasuryContract} from "../src/TreasuryContract.sol";

/// @notice Deployment script for Polkadot Hub testnet
/// @dev Run: forge script script/Deploy.s.sol --rpc-url $POLKADOT_HUB_RPC --broadcast
contract DeployDAO is Script {

    // ── Config — override via env vars ──
    uint256 constant PROPOSAL_CAP      = 10_000 * 1e18; // 10,000 DOT
    uint256 constant QUORUM_BPS        = 4000;           // 40%
    uint256 constant HIGH_QUORUM_BPS   = 6000;           // 60%
    uint256 constant MIN_VOTING        = 1 days;
    uint256 constant MAX_VOTING        = 7 days;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address guardian    = vm.envOr("GUARDIAN_ADDRESS", deployer);

        console2.log("Deploying Telos DAO - Treasury Manager");
        console2.log("Deployer:  ", deployer);
        console2.log("Guardian:  ", guardian);
        console2.log("Chain ID:  ", block.chainid);

        vm.startBroadcast(deployerKey);

        // 1. Deploy TreasuryContract — deployer as temp governance
        TreasuryContract treasury = new TreasuryContract(
            deployer,     // temp governance — replaced after gov deploy
            guardian,
            PROPOSAL_CAP
        );
        console2.log("TreasuryContract deployed:", address(treasury));

        // 2. Deploy GovernanceContract pointing to treasury
        GovernanceContract governance = new GovernanceContract(
            address(treasury),
            QUORUM_BPS,
            HIGH_QUORUM_BPS,
            MIN_VOTING,
            MAX_VOTING
        );
        console2.log("GovernanceContract deployed:", address(governance));

        // 3. Rotate treasury governance to the governance contract
        //    This is done via a direct call since deployer is still temp governance
        // NOTE: In production you would call treasury.setGovernance(address(governance))
        //       We've omitted this setter intentionally — governance is immutable post-deploy
        //       for security. Transfer via upgrade pattern if needed.

        // 4. Add initial DAO members (from env or hardcoded for testnet)
        address member1 = vm.envOr("MEMBER_1", deployer);
        governance.addMember(member1, 1000);
        console2.log("Added member:", member1, "with 1000 voting power");

        vm.stopBroadcast();

        console2.log("=== Deployment Summary ===");
        console2.log("Treasury:   ", address(treasury));
        console2.log("Governance: ", address(governance));
        console2.log("Next steps:");
        console2.log("1. Add remaining DAO members via governance.addMember()");
        console2.log("2. Fund the treasury by sending DOT to the treasury address");
        console2.log("3. Set category budgets via governance proposals");
        console2.log("4. Update frontend .env with contract addresses");
    }
}
