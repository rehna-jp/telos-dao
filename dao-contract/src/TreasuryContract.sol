// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SpendingRules} from "./SpendingRules.sol";
import {IXCMPrecompile} from "./interfaces/IXCMPrecompile.sol";
import {IAssetHub} from "./interfaces/IAssetHub.sol";
import {XCMHelper} from "./XCMHelper.sol";

/// @title TreasuryContract
/// @notice Custodies DAO assets and dispatches approved transfers — locally or cross-chain via XCM
/// @dev Only callable by the GovernanceContract after a proposal passes
contract TreasuryContract {
    using SpendingRules for SpendingRules.Rules;
    using SpendingRules for SpendingRules.CategoryBudget;
    using XCMHelper for uint32;

    // ─────────────────────────────────────────────
    // Precompile addresses (Polkadot Hub — verified from docs)
    // ─────────────────────────────────────────────

    /// @dev XCM precompile: https://docs.polkadot.com/develop/smart-contracts/precompiles/xcm-precompile/
    IXCMPrecompile public constant XCM = IXCMPrecompile(0x00000000000000000000000000000000000a0000);

    /// @dev Asset Hub precompile for native asset balance queries
    IAssetHub public constant ASSET_HUB = IAssetHub(0x0000000000000000000000000000000000000806);

    // ─────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────
    error NotGovernance();
    error NotGuardian();
    error ZeroAddress();
    error TransferFailed();
    error XCMFailed();
    error InvalidAmount();

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────
    event FundsReceived(address indexed from, uint256 amount);
    event LocalTransferExecuted(
        uint256 indexed proposalId,
        address indexed recipient,
        uint256 amount,
        bytes32 category
    );
    event CrossChainTransferExecuted(
        uint256 indexed proposalId,
        uint32 indexed targetParaId,
        bytes32 recipient,
        uint256 amount,
        bytes32 category
    );
    event SpendingRulesUpdated(uint256 proposalCap, bool whitelistEnabled);
    event CategoryBudgetSet(bytes32 indexed category, uint256 limit, uint256 periodLength);
    event RecipientWhitelisted(address indexed recipient, bool status);
    event TreasuryPauseToggled(bool paused);
    event GuardianUpdated(address indexed newGuardian);

    // ─────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────

    /// @notice The governance contract — sole authority to execute transfers
    address public governance;

    /// @notice Guardian can pause in emergencies; cannot transfer funds
    address public guardian;

    /// @notice Active spending rules
    SpendingRules.Rules public rules;

    /// @notice Category budgets — keyed by keccak256(category name)
    mapping(bytes32 => SpendingRules.CategoryBudget) public categoryBudgets;

    /// @notice Whitelisted recipients
    mapping(address => bool) public whitelist;

    /// @notice Execution history — proposalId => executed
    mapping(uint256 => bool) public executed;

    // ─────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    // ─────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────

    /// @param _governance Address of the GovernanceContract
    /// @param _guardian Address of the emergency guardian
    /// @param _proposalCap Max amount per proposal before high-quorum is required
    constructor(address _governance, address _guardian, uint256 _proposalCap) {
        if (_governance == address(0) || _guardian == address(0)) revert ZeroAddress();
        governance = _governance;
        guardian = _guardian;
        rules.proposalCap = _proposalCap;
        rules.paused = false;
        rules.whitelistEnabled = false;
    }

    /// @notice Accept native DOT deposits
    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }

    // ─────────────────────────────────────────────
    // Execution — called by GovernanceContract only
    // ─────────────────────────────────────────────

    /// @notice Execute a local (same-chain) transfer after a proposal passes
    /// @param proposalId The passed proposal ID
    /// @param recipient Recipient address on Polkadot Hub
    /// @param amount Amount in wei (DOT)
    /// @param category Spending category for budget tracking
    function executeLocalTransfer(
        uint256 proposalId,
        address recipient,
        uint256 amount,
        bytes32 category
    ) external onlyGovernance {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (executed[proposalId]) revert("Already executed");

        // Validate against spending rules
        rules.validate(
            categoryBudgets[category],
            category,
            amount,
            recipient,
            whitelist
        );

        executed[proposalId] = true;

        // Record spend before transfer (CEI pattern)
        categoryBudgets[category].recordSpend(amount);

        // Execute transfer
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit LocalTransferExecuted(proposalId, recipient, amount, category);
    }

    /// @notice Execute a cross-chain transfer via XCM after a proposal passes
    /// @param proposalId    The passed proposal ID
    /// @param targetParaId  Destination parachain ID
    /// @param recipient     32-byte AccountId32 of the beneficiary on the target chain
    /// @param amount        Amount in planck (1 DOT = 10_000_000_000 planck)
    /// @param category      Spending category
    function executeCrossChainTransfer(
        uint256 proposalId,
        uint32 targetParaId,
        bytes32 recipient,
        uint256 amount,
        bytes32 category
    ) external onlyGovernance {
        if (amount == 0) revert InvalidAmount();
        if (executed[proposalId]) revert("Already executed");

        // Validate against spending rules (whitelist not applicable cross-chain)
        rules.validate(
            categoryBudgets[category],
            category,
            amount,
            address(0),
            whitelist
        );

        executed[proposalId] = true;
        categoryBudgets[category].recordSpend(amount);

        // Dispatch via XCMHelper — handles SCALE encoding and weight estimation
        XCMHelper.transferDOTToPara(targetParaId, recipient, amount);

        emit CrossChainTransferExecuted(proposalId, targetParaId, recipient, amount, category);
    }

    // ─────────────────────────────────────────────
    // Governance-controlled configuration
    // ─────────────────────────────────────────────

    /// @notice Update spending rules — only callable via a passed governance proposal
    function updateSpendingRules(
        uint256 newCap,
        bool whitelistEnabled
    ) external onlyGovernance {
        rules.proposalCap = newCap;
        rules.whitelistEnabled = whitelistEnabled;
        emit SpendingRulesUpdated(newCap, whitelistEnabled);
    }

    /// @notice Set a category budget — only callable via governance
    function setCategoryBudget(
        bytes32 category,
        uint256 limit,
        uint256 periodLength
    ) external onlyGovernance {
        categoryBudgets[category] = SpendingRules.CategoryBudget({
            limit: limit,
            spent: 0,
            periodStart: block.timestamp,
            periodLength: periodLength
        });
        emit CategoryBudgetSet(category, limit, periodLength);
    }

    /// @notice Add/remove a whitelisted recipient — only callable via governance
    function setWhitelisted(address recipient, bool status) external onlyGovernance {
        whitelist[recipient] = status;
        emit RecipientWhitelisted(recipient, status);
    }

    /// @notice Update the guardian address — only callable via governance
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) revert ZeroAddress();
        guardian = newGuardian;
        emit GuardianUpdated(newGuardian);
    }

    // ─────────────────────────────────────────────
    // Guardian — emergency pause only
    // ─────────────────────────────────────────────

    /// @notice Transfer governance to a new address — only callable by current governance
    /// @dev Used during deployment to hand off from deployer to GovernanceContract
    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        governance = newGovernance;
    }

    /// @notice Emergency pause/unpause all outflows
    /// @dev Guardian cannot move funds — only freeze them pending governance review
    function togglePause() external onlyGuardian {
        rules.paused = !rules.paused;
        emit TreasuryPauseToggled(rules.paused);
    }

    // ─────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────

    /// @notice Native DOT balance of the treasury
    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Get balance of a native Polkadot asset via Asset Hub precompile
    function assetBalance(uint128 assetId) external view returns (uint256) {
        return ASSET_HUB.balanceOf(assetId, address(this));
    }

    /// @notice Check if a proposal has been executed
    function isExecuted(uint256 proposalId) external view returns (bool) {
        return executed[proposalId];
    }

    /// @notice Preview whether a transfer would pass spending rules
    function canExecute(
        address recipient,
        uint256 amount,
        bytes32 category
    ) external view returns (bool ok, string memory reason) {
        if (rules.paused) return (false, "Treasury paused");
        if (amount > rules.proposalCap) return (false, "Exceeds proposal cap");
        if (rules.whitelistEnabled && !whitelist[recipient]) return (false, "Recipient not whitelisted");
        SpendingRules.CategoryBudget storage b = categoryBudgets[category];
        if (b.limit > 0) {
            uint256 spent = block.timestamp >= b.periodStart + b.periodLength ? 0 : b.spent;
            if (spent + amount > b.limit) return (false, "Exceeds category budget");
        }
        return (true, "");
    }
}
