// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GovernanceContract} from "../src/GovernanceContract.sol";
import {TreasuryContract} from "../src/TreasuryContract.sol";
import {SpendingRules} from "../src/SpendingRules.sol";
import {XCMHelper} from "../src/XCMHelper.sol";

/// @notice Mock XCM precompile — matches the real IXCMPrecompile interface
contract MockXCMPrecompile {
    bytes public lastMessage;
    uint64 public lastWeight;
    uint256 public executeCallCount;
    uint256 public weighCallCount;
    bool public shouldReturnZeroWeight;

    function setShouldReturnZeroWeight(bool v) external { shouldReturnZeroWeight = v; }

    function weighMessage(bytes calldata message)
        external
        returns (uint64 refTime, uint64 proofSize)
    {
        weighCallCount++;
        lastMessage = message;
        if (shouldReturnZeroWeight) return (0, 0);
        return (1_000_000_000, 65_536);
    }

    function execute(bytes calldata message, uint64 weight) external {
        executeCallCount++;
        lastMessage = message;
        lastWeight = weight;
    }

    function send(bytes calldata, bytes calldata) external {}
}

/// @notice Mock Asset Hub precompile — matches IAssetHub interface
contract MockAssetHub {
    mapping(uint128 => mapping(address => uint256)) public balances;

    function setBalance(uint128 assetId, address who, uint256 amount) external {
        balances[assetId][who] = amount;
    }

    function balanceOf(uint128 assetId, address who) external view returns (uint256) {
        return balances[assetId][who];
    }

    function transfer(uint128 assetId, address to, uint256 amount) external returns (bool) {
        balances[assetId][msg.sender] -= amount;
        balances[assetId][to] += amount;
        return true;
    }

    function assetMetadata(uint128) external pure returns (string memory, string memory, uint8) {
        return ("Polkadot", "DOT", 10);
    }
}

contract DAOTreasuryTest is Test {

    GovernanceContract internal gov;
    TreasuryContract internal treasury;

    address internal admin     = makeAddr("admin");
    address internal alice     = makeAddr("alice");   // 400 vp
    address internal bob       = makeAddr("bob");     // 300 vp
    address internal carol     = makeAddr("carol");   // 300 vp
    address internal guardian  = makeAddr("guardian");
    address internal recipient = makeAddr("recipient");

    uint256 constant PROPOSAL_CAP    = 1_000 ether;
    uint256 constant QUORUM_BPS      = 4000; // 40%
    uint256 constant HIGH_QUORUM_BPS = 6000; // 60%
    uint256 constant MIN_DURATION    = 1 hours;
    uint256 constant MAX_DURATION    = 7 days;

    bytes32 constant CATEGORY_GRANTS = keccak256("grants");
    bytes32 constant CATEGORY_OPS    = keccak256("operations");

    // Substrate public key used as xcmRecipient for cross-chain proposals
    bytes32 constant SUBSTRATE_RECIPIENT = bytes32(
        0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d
    );

    // ─────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────

    function setUp() public {
        // Deploy mock XCM precompile at the real precompile address
        MockXCMPrecompile mockXCM = new MockXCMPrecompile();
        vm.etch(XCMHelper.XCM_PRECOMPILE, address(mockXCM).code);

        vm.startPrank(admin);

        // Deploy treasury with admin as temp governance
        treasury = new TreasuryContract(admin, guardian, PROPOSAL_CAP);

        // Deploy governance pointing to treasury
        gov = new GovernanceContract(
            address(treasury),
            QUORUM_BPS,
            HIGH_QUORUM_BPS,
            MIN_DURATION,
            MAX_DURATION
        );

        // Add members
        gov.addMember(alice, 400); // 40%
        gov.addMember(bob,   300); // 30%
        gov.addMember(carol, 300); // 30%
        // Total: 1000 voting power

        vm.stopPrank();

        // Fund the treasury
        vm.deal(address(treasury), 10_000 ether);
    }

    // ─────────────────────────────────────────────
    // Proposal Creation — Local
    // ─────────────────────────────────────────────

    function test_CreateLocalProposal() public {
        vm.prank(alice);
        uint256 pid = gov.proposeLocalTransfer(
            "Fund Dev Grant",
            "Grant for protocol dev work",
            recipient,
            100 ether,
            CATEGORY_GRANTS,
            2 days
        );

        assertEq(pid, 1);
        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.title, "Fund Dev Grant");
        assertEq(p.amount, 100 ether);
        assertEq(p.localRecipient, recipient);
        assertEq(p.xcmRecipient, bytes32(0));
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Active));
        assertEq(uint8(p.transferType), uint8(GovernanceContract.TransferType.Local));
        assertFalse(p.requiresHighQuorum);
    }

    function test_CreateLocalProposal_LargeAmount_SetsHighQuorum() public {
        vm.prank(alice);
        uint256 pid = gov.proposeLocalTransfer(
            "Large Grant",
            "Amount exceeds cap",
            recipient,
            2_000 ether, // > PROPOSAL_CAP
            CATEGORY_GRANTS,
            2 days
        );

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertTrue(p.requiresHighQuorum, "Large proposal should require high quorum");
        assertEq(p.quorumRequired, 600); // 1000 vp * 60% = 600
    }

    function test_RevertIf_NonMemberProposes() public {
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(GovernanceContract.NotMember.selector);
        gov.proposeLocalTransfer("Bad Prop", "desc", recipient, 1 ether, CATEGORY_GRANTS, 2 days);
    }

    function test_RevertIf_DurationTooShort() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceContract.InvalidDuration.selector);
        gov.proposeLocalTransfer("Prop", "desc", recipient, 1 ether, CATEGORY_GRANTS, 30 minutes);
    }

    function test_RevertIf_DurationTooLong() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceContract.InvalidDuration.selector);
        gov.proposeLocalTransfer("Prop", "desc", recipient, 1 ether, CATEGORY_GRANTS, 8 days);
    }

    // ─────────────────────────────────────────────
    // Proposal Creation — Cross-Chain
    // ─────────────────────────────────────────────

    function test_CreateCrossChainProposal_Astar() public {
        vm.prank(alice);
        uint256 pid = gov.proposeCrossChainTransfer(
            "XCM Grant to Astar",
            "Cross-chain transfer to Astar",
            2006,                // Astar paraId
            SUBSTRATE_RECIPIENT, // bytes32 AccountId32
            50 ether,
            CATEGORY_GRANTS,
            2 days
        );

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.transferType), uint8(GovernanceContract.TransferType.CrossChain));
        assertEq(p.targetParaId, 2006);
        assertEq(p.xcmRecipient, SUBSTRATE_RECIPIENT);
        assertEq(p.amount, 50 ether);
        assertEq(p.localRecipient, address(0));
    }

    function test_CreateCrossChainProposal_Moonbeam() public {
        // Moonbeam uses AccountKey20 — pass EVM address cast to bytes32
        address moonbeamAddr = makeAddr("moonbeam_recipient");
        bytes32 xcmRecipient = bytes32(uint256(uint160(moonbeamAddr)));

        vm.prank(bob);
        uint256 pid = gov.proposeCrossChainTransfer(
            "XCM Grant to Moonbeam",
            "Cross-chain transfer to Moonbeam",
            2004,         // Moonbeam paraId
            xcmRecipient,
            100 ether,
            CATEGORY_GRANTS,
            2 days
        );

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.targetParaId, 2004);
        assertEq(p.xcmRecipient, xcmRecipient);
    }

    function test_RevertIf_NonMemberCreatesCrossChainProposal() public {
        vm.prank(makeAddr("outsider"));
        vm.expectRevert(GovernanceContract.NotMember.selector);
        gov.proposeCrossChainTransfer(
            "P", "d", 2006, SUBSTRATE_RECIPIENT, 10 ether, CATEGORY_GRANTS, 2 days
        );
    }

    // ─────────────────────────────────────────────
    // Voting
    // ─────────────────────────────────────────────

    function test_CastVoteFor() public {
        uint256 pid = _createBasicProposal();

        vm.prank(alice);
        gov.castVote(pid, true);

        (uint256 vFor, uint256 vAgainst,,,) = gov.getVoteSummary(pid);
        assertEq(vFor, 400);
        assertEq(vAgainst, 0);
        assertTrue(gov.hasVoted(pid, alice));
    }

    function test_CastVoteAgainst() public {
        uint256 pid = _createBasicProposal();

        vm.prank(bob);
        gov.castVote(pid, false);

        (uint256 vFor, uint256 vAgainst,,,) = gov.getVoteSummary(pid);
        assertEq(vFor, 0);
        assertEq(vAgainst, 300);
    }

    function test_RevertIf_DoubleVote() public {
        uint256 pid = _createBasicProposal();

        vm.prank(alice);
        gov.castVote(pid, true);

        vm.prank(alice);
        vm.expectRevert(GovernanceContract.AlreadyVoted.selector);
        gov.castVote(pid, true);
    }

    function test_RevertIf_VoteAfterDeadline() public {
        uint256 pid = _createBasicProposal();
        vm.warp(block.timestamp + 3 days);

        vm.prank(alice);
        vm.expectRevert(GovernanceContract.ProposalNotActive.selector);
        gov.castVote(pid, true);
    }

    // ─────────────────────────────────────────────
    // Finalization
    // ─────────────────────────────────────────────

    function test_ProposalPasses_WithQuorumAndMajority() public {
        uint256 pid = _createBasicProposal();

        vm.prank(alice); gov.castVote(pid, true); // 400
        vm.prank(bob);   gov.castVote(pid, true); // 300 → total 700 > 40% quorum

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Passed));
    }

    function test_ProposalDefeated_InsufficientQuorum() public {
        uint256 pid = _createBasicProposal();

        vm.prank(carol); gov.castVote(pid, true); // 300 < 40% quorum (400 needed)

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Defeated));
    }

    function test_ProposalDefeated_MajorityAgainst() public {
        uint256 pid = _createBasicProposal();

        vm.prank(alice); gov.castVote(pid, false); // 400 against
        vm.prank(bob);   gov.castVote(pid, false); // 300 against
        vm.prank(carol); gov.castVote(pid, true);  // 300 for

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Defeated));
    }

    function test_RevertIf_FinalizeBeforeDeadline() public {
        uint256 pid = _createBasicProposal();
        vm.prank(alice); gov.castVote(pid, true);

        vm.expectRevert(GovernanceContract.VotingStillActive.selector);
        gov.finalizeProposal(pid);
    }

    // ─────────────────────────────────────────────
    // Execution — Local Transfer
    // ─────────────────────────────────────────────

    function test_ExecuteLocalTransfer() public {
        vm.prank(admin);
        TreasuryContract execTreasury = new TreasuryContract(admin, guardian, PROPOSAL_CAP);
        vm.deal(address(execTreasury), 10_000 ether);

        vm.prank(admin);
        GovernanceContract execGov = new GovernanceContract(
            address(execTreasury), QUORUM_BPS, HIGH_QUORUM_BPS, MIN_DURATION, MAX_DURATION
        );

        // Hand governance over to execGov
        vm.prank(admin);
        execTreasury.setGovernance(address(execGov));

        vm.prank(admin); execGov.addMember(alice, 400);
        vm.prank(admin); execGov.addMember(bob,   300);
        vm.prank(admin); execGov.addMember(carol, 300);

        uint256 balanceBefore = recipient.balance;

        vm.prank(alice);
        uint256 pid = execGov.proposeLocalTransfer(
            "Pay contributor", "desc", recipient, 100 ether, CATEGORY_GRANTS, 2 days
        );

        vm.prank(alice); execGov.castVote(pid, true);
        vm.prank(bob);   execGov.castVote(pid, true);
        vm.warp(block.timestamp + 3 days);
        execGov.finalizeProposal(pid);
        execGov.executeProposal(pid);

        assertEq(recipient.balance, balanceBefore + 100 ether);

        GovernanceContract.Proposal memory p = execGov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Executed));
        assertTrue(execTreasury.isExecuted(pid));
    }

    function test_RevertIf_ExecuteNotPassedProposal() public {
        uint256 pid = _createBasicProposal();

        vm.expectRevert(GovernanceContract.ProposalNotPassed.selector);
        gov.executeProposal(pid);
    }

    function test_RevertIf_ExecuteSameProposalTwice() public {
        vm.prank(admin);
        TreasuryContract execTreasury = new TreasuryContract(admin, guardian, PROPOSAL_CAP);
        vm.deal(address(execTreasury), 10_000 ether);

        vm.prank(admin);
        GovernanceContract execGov = new GovernanceContract(
            address(execTreasury), QUORUM_BPS, HIGH_QUORUM_BPS, MIN_DURATION, MAX_DURATION
        );

        vm.prank(admin);
        execTreasury.setGovernance(address(execGov));

        vm.prank(admin); execGov.addMember(alice, 400);
        vm.prank(admin); execGov.addMember(bob,   600);

        vm.prank(alice);
        uint256 pid = execGov.proposeLocalTransfer(
            "Pay", "desc", recipient, 100 ether, CATEGORY_GRANTS, 2 days
        );
        vm.prank(alice); execGov.castVote(pid, true);
        vm.prank(bob);   execGov.castVote(pid, true);
        vm.warp(block.timestamp + 3 days);
        execGov.finalizeProposal(pid);
        execGov.executeProposal(pid);

        vm.expectRevert(GovernanceContract.ProposalNotPassed.selector);
        execGov.executeProposal(pid);
    }

    // ─────────────────────────────────────────────
    // Execution — Cross-Chain via XCM
    // ─────────────────────────────────────────────

    function test_ExecuteCrossChainTransfer_CallsXCMPrecompile() public {
        vm.prank(admin);
        TreasuryContract execTreasury = new TreasuryContract(admin, guardian, PROPOSAL_CAP);
        vm.deal(address(execTreasury), 10_000 ether);

        vm.prank(admin);
        GovernanceContract execGov = new GovernanceContract(
            address(execTreasury), QUORUM_BPS, HIGH_QUORUM_BPS, MIN_DURATION, MAX_DURATION
        );

        vm.prank(admin);
        execTreasury.setGovernance(address(execGov));

        vm.prank(admin); execGov.addMember(alice, 400);
        vm.prank(admin); execGov.addMember(bob,   300);
        vm.prank(admin); execGov.addMember(carol, 300);

        vm.prank(alice);
        uint256 pid = execGov.proposeCrossChainTransfer(
            "XCM to Astar", "desc",
            2006,
            SUBSTRATE_RECIPIENT,
            50 ether,
            CATEGORY_GRANTS,
            2 days
        );

        vm.prank(alice); execGov.castVote(pid, true);
        vm.prank(bob);   execGov.castVote(pid, true);
        vm.warp(block.timestamp + 3 days);
        execGov.finalizeProposal(pid);
        execGov.executeProposal(pid);

        MockXCMPrecompile xcm = MockXCMPrecompile(XCMHelper.XCM_PRECOMPILE);
        assertEq(xcm.executeCallCount(), 1, "XCM execute must be called once");
        assertEq(xcm.weighCallCount(), 1, "XCM weighMessage must be called first");
        assertTrue(xcm.lastMessage().length > 0, "XCM message must be non-empty");

        GovernanceContract.Proposal memory p = execGov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Executed));
    }

    // ─────────────────────────────────────────────
    // Spending Rules
    // ─────────────────────────────────────────────

    function test_SpendingRules_CategoryBudget() public {
        vm.prank(admin);
        treasury.setCategoryBudget(CATEGORY_GRANTS, 500 ether, 30 days);

        (bool ok, string memory reason) = treasury.canExecute(recipient, 600 ether, CATEGORY_GRANTS);
        assertFalse(ok);
        assertEq(reason, "Exceeds category budget");
    }

    function test_SpendingRules_ExceedsProposalCap() public view {
        (bool ok, string memory reason) = treasury.canExecute(recipient, 2_000 ether, CATEGORY_GRANTS);
        assertFalse(ok);
        assertEq(reason, "Exceeds proposal cap");
    }

    function test_EmergencyPause_BlocksExecution() public {
        vm.prank(guardian);
        treasury.togglePause();

        (bool ok, string memory reason) = treasury.canExecute(recipient, 1 ether, CATEGORY_GRANTS);
        assertFalse(ok);
        assertEq(reason, "Treasury paused");
    }

    function test_EmergencyPause_Unpause_AllowsExecution() public {
        vm.prank(guardian);
        treasury.togglePause();

        vm.prank(guardian);
        treasury.togglePause();

        (bool ok,) = treasury.canExecute(recipient, 1 ether, CATEGORY_GRANTS);
        assertTrue(ok);
    }

    function test_Whitelist_BlocksUnknownRecipient() public {
        vm.prank(admin);
        treasury.updateSpendingRules(PROPOSAL_CAP, true); // enable whitelist

        (bool ok, string memory reason) = treasury.canExecute(recipient, 100 ether, CATEGORY_GRANTS);
        assertFalse(ok);
        assertEq(reason, "Recipient not whitelisted");
    }

    function test_Whitelist_AllowsWhitelistedRecipient() public {
        vm.startPrank(admin);
        treasury.updateSpendingRules(PROPOSAL_CAP, true);
        treasury.setWhitelisted(recipient, true);
        vm.stopPrank();

        (bool ok,) = treasury.canExecute(recipient, 100 ether, CATEGORY_GRANTS);
        assertTrue(ok);
    }

    // ─────────────────────────────────────────────
    // AI Summary
    // ─────────────────────────────────────────────

    function test_SubmitAISummary() public {
        uint256 pid = _createBasicProposal();

        string memory summary = "Risk: LOW. 100 DOT for protocol dev. Recipient is a known contributor.";
        vm.prank(alice);
        gov.submitAISummary(pid, summary);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.aiSummary, summary);
    }

    function test_AISummary_StoredOnChain_Verifiable() public {
        uint256 pid = _createBasicProposal();

        vm.prank(alice);
        gov.submitAISummary(pid, "Transparent on-chain AI analysis.");

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertTrue(bytes(p.aiSummary).length > 0);
    }

    function test_RevertIf_UnauthorizedSummarySubmission() public {
        uint256 pid = _createBasicProposal();

        vm.prank(bob); // not the proposer or admin
        vm.expectRevert("Not authorized");
        gov.submitAISummary(pid, "Unauthorized summary");
    }

    // ─────────────────────────────────────────────
    // Treasury Views
    // ─────────────────────────────────────────────

    function test_TreasuryBalance() public view {
        assertEq(treasury.balance(), 10_000 ether);
    }

    function test_CanExecute_HappyPath() public view {
        (bool ok, string memory reason) = treasury.canExecute(recipient, 100 ether, CATEGORY_GRANTS);
        assertTrue(ok);
        assertEq(reason, "");
    }

    function test_IsExecuted_ReturnsFalse_BeforeExecution() public view {
        assertFalse(treasury.isExecuted(1));
        assertFalse(treasury.isExecuted(999));
    }

    function test_GetActiveProposals() public {
        vm.prank(alice);
        gov.proposeLocalTransfer("P1", "d", recipient, 10 ether, CATEGORY_GRANTS, 2 days);
        vm.prank(alice);
        gov.proposeLocalTransfer("P2", "d", recipient, 20 ether, CATEGORY_GRANTS, 2 days);

        uint256[] memory active = gov.getActiveProposals();
        assertEq(active.length, 2);
        assertEq(active[0], 1);
        assertEq(active[1], 2);
    }

    // ─────────────────────────────────────────────
    // Member Management
    // ─────────────────────────────────────────────

    function test_AddMember() public {
        address dave = makeAddr("dave");
        vm.prank(admin);
        gov.addMember(dave, 200);

        assertEq(gov.votingPower(dave), 200);
        assertEq(gov.totalVotingPower(), 1200);
    }

    function test_RemoveMember() public {
        vm.prank(admin);
        gov.removeMember(carol);

        assertEq(gov.votingPower(carol), 0);
        assertEq(gov.totalVotingPower(), 700);
    }

    function test_RevertIf_AddExistingMember() public {
        vm.prank(admin);
        vm.expectRevert(GovernanceContract.AlreadyMember.selector);
        gov.addMember(alice, 100);
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _createBasicProposal() internal returns (uint256) {
        vm.prank(alice);
        return gov.proposeLocalTransfer(
            "Basic Proposal",
            "Transfer 100 DOT for dev work",
            recipient,
            100 ether,
            CATEGORY_GRANTS,
            2 days
        );
    }
}
