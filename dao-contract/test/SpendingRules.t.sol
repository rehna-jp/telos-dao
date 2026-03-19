// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SpendingRules} from "../src/SpendingRules.sol";

/// @notice Harness contract that exposes the SpendingRules library for testing
/// @dev Libraries with storage pointers can't be tested directly — harness wraps them
contract SpendingRulesHarness {
    using SpendingRules for SpendingRules.Rules;
    using SpendingRules for SpendingRules.CategoryBudget;

    SpendingRules.Rules public rules;
    mapping(bytes32 => SpendingRules.CategoryBudget) public budgets;
    mapping(address => bool) public whitelist;

    // ── Rules setup ──

    function setProposalCap(uint256 cap) external {
        rules.proposalCap = cap;
    }

    function setPaused(bool paused) external {
        rules.paused = paused;
    }

    function setWhitelistEnabled(bool enabled) external {
        rules.whitelistEnabled = enabled;
    }

    function setWhitelisted(address addr, bool status) external {
        whitelist[addr] = status;
    }

    // ── Budget setup ──

    function setBudget(bytes32 category, uint256 limit, uint256 periodLength) external {
        budgets[category] = SpendingRules.CategoryBudget({
            limit: limit,
            spent: 0,
            periodStart: block.timestamp,
            periodLength: periodLength
        });
    }

    function getBudget(bytes32 category)
        external
        view
        returns (uint256 limit, uint256 spent, uint256 periodStart, uint256 periodLength)
    {
        SpendingRules.CategoryBudget storage b = budgets[category];
        return (b.limit, b.spent, b.periodStart, b.periodLength);
    }

    // ── Library calls ──

    function validate(
        bytes32 category,
        uint256 amount,
        address recipient
    ) external view {
        rules.validate(budgets[category], category, amount, recipient, whitelist);
    }

    function recordSpend(bytes32 category, uint256 amount) external {
        budgets[category].recordSpend(amount);
    }

    function requiresHighQuorum(uint256 amount) external view returns (bool) {
        return rules.requiresHighQuorum(amount);
    }
}

contract SpendingRulesTest is Test {

    SpendingRulesHarness internal h;

    address internal alice     = makeAddr("alice");
    address internal bob       = makeAddr("bob");
    address internal outsider  = makeAddr("outsider");

    bytes32 constant CAT_GRANTS = keccak256("grants");
    bytes32 constant CAT_OPS    = keccak256("operations");
    bytes32 constant CAT_EMPTY  = bytes32(0);

    uint256 constant CAP        = 1_000 ether;
    uint256 constant PERIOD     = 30 days;

    // ─────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────

    function setUp() public {
        h = new SpendingRulesHarness();
        h.setProposalCap(CAP);
    }

    // ─────────────────────────────────────────────
    // Emergency Pause
    // ─────────────────────────────────────────────

    function test_Validate_Passes_WhenUnpaused() public view {
        // Should not revert
        h.validate(CAT_EMPTY, 100 ether, alice);
    }

    function test_Validate_Reverts_WhenPaused() public {
        h.setPaused(true);

        vm.expectRevert(SpendingRules.TreasuryPaused.selector);
        h.validate(CAT_EMPTY, 100 ether, alice);
    }

    function test_Validate_Passes_AfterUnpause() public {
        h.setPaused(true);
        h.setPaused(false);

        // Should not revert
        h.validate(CAT_EMPTY, 100 ether, alice);
    }

    // ─────────────────────────────────────────────
    // Proposal Cap
    // ─────────────────────────────────────────────

    function test_Validate_Passes_AtExactCap() public view {
        // Exact cap amount should pass
        h.validate(CAT_EMPTY, CAP, alice);
    }

    function test_Validate_Reverts_AboveCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.ExceedsProposalCap.selector, CAP + 1, CAP)
        );
        h.validate(CAT_EMPTY, CAP + 1, alice);
    }

    function test_Validate_Passes_BelowCap() public view {
        h.validate(CAT_EMPTY, CAP - 1, alice);
    }

    function test_Validate_Passes_ZeroAmount() public view {
        // Zero amount is technically valid from rules perspective
        // (InvalidAmount check is in TreasuryContract, not library)
        h.validate(CAT_EMPTY, 0, alice);
    }

    function test_RequiresHighQuorum_AboveCap() public view {
        assertTrue(h.requiresHighQuorum(CAP + 1));
        assertTrue(h.requiresHighQuorum(CAP * 10));
    }

    function test_RequiresHighQuorum_AtOrBelowCap() public view {
        assertFalse(h.requiresHighQuorum(CAP));
        assertFalse(h.requiresHighQuorum(CAP - 1));
        assertFalse(h.requiresHighQuorum(0));
    }

    // ─────────────────────────────────────────────
    // Whitelist
    // ─────────────────────────────────────────────

    function test_Validate_Passes_WhitelistDisabled_AnyRecipient() public view {
        // Whitelist disabled by default — any recipient passes
        h.validate(CAT_EMPTY, 100 ether, outsider);
    }

    function test_Validate_Passes_WhitelistEnabled_WhitelistedRecipient() public {
        h.setWhitelistEnabled(true);
        h.setWhitelisted(alice, true);

        h.validate(CAT_EMPTY, 100 ether, alice); // should not revert
    }

    function test_Validate_Reverts_WhitelistEnabled_UnknownRecipient() public {
        h.setWhitelistEnabled(true);
        h.setWhitelisted(alice, true);

        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.RecipientNotWhitelisted.selector, outsider)
        );
        h.validate(CAT_EMPTY, 100 ether, outsider);
    }

    function test_Validate_Passes_AfterAddingToWhitelist() public {
        h.setWhitelistEnabled(true);

        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.RecipientNotWhitelisted.selector, bob)
        );
        h.validate(CAT_EMPTY, 100 ether, bob);

        // Now add bob to whitelist
        h.setWhitelisted(bob, true);
        h.validate(CAT_EMPTY, 100 ether, bob); // should pass now
    }

    function test_Validate_Reverts_AfterRemovingFromWhitelist() public {
        h.setWhitelistEnabled(true);
        h.setWhitelisted(alice, true);

        h.validate(CAT_EMPTY, 100 ether, alice); // passes

        h.setWhitelisted(alice, false);

        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.RecipientNotWhitelisted.selector, alice)
        );
        h.validate(CAT_EMPTY, 100 ether, alice);
    }

    // ─────────────────────────────────────────────
    // Category Budget
    // ─────────────────────────────────────────────

    function test_Validate_Passes_NoBudgetSet() public view {
        // No budget configured for CAT_GRANTS — should pass any amount up to cap
        h.validate(CAT_GRANTS, 500 ether, alice);
    }

    function test_Validate_Passes_UnderBudget() public {
        h.setBudget(CAT_GRANTS, 500 ether, PERIOD);
        h.validate(CAT_GRANTS, 499 ether, alice); // should not revert
    }

    function test_Validate_Passes_AtExactBudget() public {
        h.setBudget(CAT_GRANTS, 500 ether, PERIOD);
        h.validate(CAT_GRANTS, 500 ether, alice); // exactly at limit — should pass
    }

    function test_Validate_Reverts_OverBudget() public {
        h.setBudget(CAT_GRANTS, 500 ether, PERIOD);

        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.ExceedsCategoryBudget.selector, CAT_GRANTS, 0, 500 ether)
        );
        h.validate(CAT_GRANTS, 501 ether, alice);
    }

    function test_Validate_Reverts_BudgetPartiallySpent() public {
        h.setBudget(CAT_GRANTS, 500 ether, PERIOD);
        h.recordSpend(CAT_GRANTS, 400 ether); // 400 already spent

        // 200 more would exceed 500 limit
        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.ExceedsCategoryBudget.selector, CAT_GRANTS, 400 ether, 500 ether)
        );
        h.validate(CAT_GRANTS, 200 ether, alice);
    }

    function test_Validate_Passes_ExactRemainingBudget() public {
        h.setBudget(CAT_GRANTS, 500 ether, PERIOD);
        h.recordSpend(CAT_GRANTS, 300 ether); // 300 spent, 200 remaining

        h.validate(CAT_GRANTS, 200 ether, alice); // exactly remaining — should pass
    }

    function test_Validate_NoCategoryCheck_WhenCategoryIsZero() public {
        // CAT_EMPTY (bytes32(0)) skips budget check even if budget has limit
        h.setBudget(CAT_EMPTY, 100 ether, PERIOD); // limit set for zero category
        // But the library skips check when category == bytes32(0)
        h.validate(CAT_EMPTY, 500 ether, alice); // should pass (skips budget check)
    }

    // ─────────────────────────────────────────────
    // recordSpend & Period Reset
    // ─────────────────────────────────────────────

    function test_RecordSpend_AccumulatesWithinPeriod() public {
        h.setBudget(CAT_GRANTS, 1_000 ether, PERIOD);

        h.recordSpend(CAT_GRANTS, 200 ether);
        h.recordSpend(CAT_GRANTS, 300 ether);

        (, uint256 spent,,) = h.getBudget(CAT_GRANTS);
        assertEq(spent, 500 ether);
    }

    function test_RecordSpend_ResetsOnNewPeriod() public {
        h.setBudget(CAT_GRANTS, 1_000 ether, PERIOD);

        h.recordSpend(CAT_GRANTS, 800 ether);

        (, uint256 spentBefore,,) = h.getBudget(CAT_GRANTS);
        assertEq(spentBefore, 800 ether);

        // Advance past the period
        vm.warp(block.timestamp + PERIOD + 1);

        h.recordSpend(CAT_GRANTS, 100 ether); // triggers period reset

        (, uint256 spentAfter,,) = h.getBudget(CAT_GRANTS);
        assertEq(spentAfter, 100 ether); // reset to just this spend
    }

    function test_Validate_AllowsFullBudget_AfterPeriodExpires() public {
        h.setBudget(CAT_GRANTS, 500 ether, PERIOD);
        h.recordSpend(CAT_GRANTS, 500 ether); // fully spent

        // Still in period — should revert
        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.ExceedsCategoryBudget.selector, CAT_GRANTS, 500 ether, 500 ether)
        );
        h.validate(CAT_GRANTS, 1 ether, alice);

        // Advance past period
        vm.warp(block.timestamp + PERIOD + 1);

        // Period reset — full budget available again
        h.validate(CAT_GRANTS, 500 ether, alice); // should pass
    }

    function test_RecordSpend_UpdatesPeriodStart_OnReset() public {
        h.setBudget(CAT_GRANTS, 1_000 ether, PERIOD);
        (,, uint256 startBefore,) = h.getBudget(CAT_GRANTS);

        // Advance past the period
        vm.warp(block.timestamp + PERIOD + 1);

        h.recordSpend(CAT_GRANTS, 100 ether);

        (,, uint256 startAfter,) = h.getBudget(CAT_GRANTS);
        // Period start should have been updated to current block.timestamp
        assertGt(startAfter, startBefore);
        assertEq(startAfter, block.timestamp);
    }

    // ─────────────────────────────────────────────
    // Combined Rule Interactions
    // ─────────────────────────────────────────────

    function test_Validate_PauseTakesPriority_OverAllRules() public {
        // Setup rules that would individually pass
        h.setWhitelistEnabled(true);
        h.setWhitelisted(alice, true);
        h.setBudget(CAT_GRANTS, 500 ether, PERIOD);

        h.setPaused(true); // pause overrides everything

        vm.expectRevert(SpendingRules.TreasuryPaused.selector);
        h.validate(CAT_GRANTS, 100 ether, alice);
    }

    function test_Validate_CapCheckedBeforeWhitelist() public {
        h.setWhitelistEnabled(true);
        // alice is NOT whitelisted, but amount also exceeds cap
        // Cap check runs first → should revert with ExceedsProposalCap

        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.ExceedsProposalCap.selector, CAP + 1 ether, CAP)
        );
        h.validate(CAT_GRANTS, CAP + 1 ether, alice);
    }

    function test_Validate_WhitelistCheckedBeforeBudget() public {
        h.setWhitelistEnabled(true);
        h.setBudget(CAT_GRANTS, 100 ether, PERIOD);
        // outsider not whitelisted, amount also exceeds budget
        // Whitelist check runs before budget → should revert with RecipientNotWhitelisted

        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.RecipientNotWhitelisted.selector, outsider)
        );
        h.validate(CAT_GRANTS, 200 ether, outsider);
    }

    // ─────────────────────────────────────────────
    // Fuzz Tests
    // ─────────────────────────────────────────────

    /// @notice Fuzz: spending accumulation should never exceed budget without revert
    function testFuzz_SpendAccumulation(uint256 spend1, uint256 spend2) public {
        uint256 limit = 1_000 ether;
        h.setBudget(CAT_GRANTS, limit, PERIOD);
        h.setProposalCap(limit * 10); // remove cap as a blocker

        spend1 = bound(spend1, 0, limit);
        spend2 = bound(spend2, 0, limit - spend1); // ensure combined stays within limit

        h.recordSpend(CAT_GRANTS, spend1);
        h.recordSpend(CAT_GRANTS, spend2);

        (, uint256 spent,,) = h.getBudget(CAT_GRANTS);
        assertEq(spent, spend1 + spend2);
        assertLe(spent, limit);
    }

    /// @notice Fuzz: validate should always revert above cap
    function testFuzz_AlwaysRevertsAboveCap(uint256 amount) public {
        amount = bound(amount, CAP + 1, type(uint128).max);

        vm.expectRevert(
            abi.encodeWithSelector(SpendingRules.ExceedsProposalCap.selector, amount, CAP)
        );
        h.validate(CAT_EMPTY, amount, alice);
    }

    /// @notice Fuzz: any amount at or below cap passes (no whitelist, no budget)
    function testFuzz_PassesBelowOrAtCap(uint256 amount) public view {
        amount = bound(amount, 0, CAP);
        h.validate(CAT_EMPTY, amount, alice); // should not revert
    }
}
