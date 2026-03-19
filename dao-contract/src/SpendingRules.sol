// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SpendingRules
/// @notice On-chain configurable spending controls for the DAO treasury
/// @dev Enforced before any fund dispatch — rules are set by governance itself
library SpendingRules {
    // ─────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────
    error ExceedsProposalCap(uint256 amount, uint256 cap);
    error ExceedsCategoryBudget(bytes32 category, uint256 spent, uint256 budget);
    error RecipientNotWhitelisted(address recipient);
    error TreasuryPaused();

    // ─────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────

    /// @notice Spending rule configuration stored in treasury state
    struct Rules {
        /// @dev Max amount a single proposal can request without full quorum override
        uint256 proposalCap;
        /// @dev Whether all outflows are paused (emergency stop)
        bool paused;
        /// @dev Whether recipient whitelisting is enforced
        bool whitelistEnabled;
    }

    /// @notice Per-category monthly budget tracking
    struct CategoryBudget {
        uint256 limit;        // Max spend per period
        uint256 spent;        // Spent in current period
        uint256 periodStart;  // Timestamp when the current period began
        uint256 periodLength; // Period duration in seconds (e.g. 30 days)
    }

    // ─────────────────────────────────────────────
    // Validation
    // ─────────────────────────────────────────────

    /// @notice Validate a proposed transfer against all active rules
    /// @param rules The current rule configuration
    /// @param budget The category budget for this proposal's category
    /// @param category The spending category (e.g. keccak256("grants"))
    /// @param amount The proposed transfer amount
    /// @param recipient The proposed recipient
    /// @param whitelist Mapping of whitelisted recipients
    function validate(
        Rules storage rules,
        CategoryBudget storage budget,
        bytes32 category,
        uint256 amount,
        address recipient,
        mapping(address => bool) storage whitelist
    ) internal view {
        // 1. Emergency pause check
        if (rules.paused) revert TreasuryPaused();

        // 2. Per-proposal cap
        if (amount > rules.proposalCap) {
            revert ExceedsProposalCap(amount, rules.proposalCap);
        }

        // 3. Recipient whitelist
        if (rules.whitelistEnabled && !whitelist[recipient]) {
            revert RecipientNotWhitelisted(recipient);
        }

        // 4. Category budget (only if a budget is configured)
        if (budget.limit > 0 && category != bytes32(0)) {
            uint256 effectiveSpent = _effectiveSpent(budget);
            if (effectiveSpent + amount > budget.limit) {
                revert ExceedsCategoryBudget(category, effectiveSpent, budget.limit);
            }
        }
    }

    /// @notice Record spending against a category budget after successful execution
    function recordSpend(CategoryBudget storage budget, uint256 amount) internal {
        // Reset period if expired
        if (block.timestamp >= budget.periodStart + budget.periodLength) {
            budget.spent = 0;
            budget.periodStart = block.timestamp;
        }
        budget.spent += amount;
    }

    /// @notice Returns effective spend for the current period (resets if expired)
    function _effectiveSpent(CategoryBudget storage budget) private view returns (uint256) {
        if (block.timestamp >= budget.periodStart + budget.periodLength) {
            return 0; // Period has reset
        }
        return budget.spent;
    }

    /// @notice Check if a proposal exceeds the cap but could be allowed by full quorum override
    /// @dev Governance contract uses this to require higher quorum for large proposals
    function requiresHighQuorum(Rules storage rules, uint256 amount) internal view returns (bool) {
        return amount > rules.proposalCap;
    }
}
