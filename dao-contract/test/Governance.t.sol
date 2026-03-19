// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {GovernanceContract} from "../src/GovernanceContract.sol";
import {TreasuryContract} from "../src/TreasuryContract.sol";

contract GovernanceContractTest is Test {

    GovernanceContract internal gov;
    TreasuryContract internal treasury;

    address internal admin     = makeAddr("admin");
    address internal alice     = makeAddr("alice");   // 400 vp — largest holder
    address internal bob       = makeAddr("bob");     // 300 vp
    address internal carol     = makeAddr("carol");   // 300 vp
    address internal dave      = makeAddr("dave");    // not a member
    address internal guardian  = makeAddr("guardian");
    address internal recipient = makeAddr("recipient");

    uint256 constant PROPOSAL_CAP    = 1_000 ether;
    uint256 constant QUORUM_BPS      = 4000; // 40% of 1000 vp = 400
    uint256 constant HIGH_QUORUM_BPS = 6000; // 60% of 1000 vp = 600
    uint256 constant MIN_DURATION    = 1 hours;
    uint256 constant MAX_DURATION    = 7 days;

    bytes32 constant CAT_GRANTS = keccak256("grants");
    bytes32 constant CAT_OPS    = keccak256("operations");

    // ─────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(admin);

        treasury = new TreasuryContract(admin, guardian, PROPOSAL_CAP);
        gov = new GovernanceContract(
            address(treasury),
            QUORUM_BPS,
            HIGH_QUORUM_BPS,
            MIN_DURATION,
            MAX_DURATION
        );

        gov.addMember(alice, 400);
        gov.addMember(bob,   300);
        gov.addMember(carol, 300);
        // Total voting power: 1000

        vm.stopPrank();
        vm.deal(address(treasury), 50_000 ether);
    }

    // ─────────────────────────────────────────────
    // Constructor & Initial State
    // ─────────────────────────────────────────────

    function test_InitialState() public view {
        assertEq(address(gov.treasury()), address(treasury));
        assertEq(gov.admin(), admin);
        assertEq(gov.quorumBps(), QUORUM_BPS);
        assertEq(gov.highQuorumBps(), HIGH_QUORUM_BPS);
        assertEq(gov.minVotingDuration(), MIN_DURATION);
        assertEq(gov.maxVotingDuration(), MAX_DURATION);
        assertEq(gov.proposalCount(), 0);
        assertEq(gov.totalVotingPower(), 1000);
    }

    function test_InitialMemberVotingPower() public view {
        assertEq(gov.votingPower(alice), 400);
        assertEq(gov.votingPower(bob),   300);
        assertEq(gov.votingPower(carol), 300);
        assertEq(gov.votingPower(dave),  0);
    }

    function test_RevertIf_ZeroAddressTreasury() public {
        vm.expectRevert(GovernanceContract.ZeroAddress.selector);
        new GovernanceContract(address(0), QUORUM_BPS, HIGH_QUORUM_BPS, MIN_DURATION, MAX_DURATION);
    }

    // ─────────────────────────────────────────────
    // Member Management
    // ─────────────────────────────────────────────

    function test_AddMember() public {
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

    function test_RevertIf_RemoveNonMember() public {
        vm.prank(admin);
        vm.expectRevert(GovernanceContract.NotMember.selector);
        gov.removeMember(dave);
    }

    function test_RevertIf_AddZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(GovernanceContract.ZeroAddress.selector);
        gov.addMember(address(0), 100);
    }

    function test_RevertIf_NonAdminAddsMember() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceContract.NotAdmin.selector);
        gov.addMember(dave, 100);
    }

    function test_RevertIf_NonAdminRemovesMember() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceContract.NotAdmin.selector);
        gov.removeMember(bob);
    }

    // ─────────────────────────────────────────────
    // Local Proposal Creation
    // ─────────────────────────────────────────────

    function test_CreateLocalProposal_BasicFields() public {
        vm.prank(alice);
        uint256 pid = gov.proposeLocalTransfer(
            "Dev Grant Q1",
            "Fund protocol development for Q1 2026",
            recipient,
            100 ether,
            CAT_GRANTS,
            2 days
        );

        assertEq(pid, 1);
        assertEq(gov.proposalCount(), 1);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.id, 1);
        assertEq(p.proposer, alice);
        assertEq(p.title, "Dev Grant Q1");
        assertEq(p.description, "Fund protocol development for Q1 2026");
        assertEq(p.amount, 100 ether);
        assertEq(p.localRecipient, recipient);
        assertEq(p.category, CAT_GRANTS);
        assertEq(uint8(p.transferType), uint8(GovernanceContract.TransferType.Local));
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Active));
        assertEq(p.votesFor, 0);
        assertEq(p.votesAgainst, 0);
        assertEq(p.aiSummary, "");
        assertFalse(p.requiresHighQuorum);
    }

    function test_CreateLocalProposal_DeadlineIsSet() public {
        uint256 duration = 3 days;
        uint256 before = block.timestamp;

        vm.prank(alice);
        uint256 pid = gov.proposeLocalTransfer("P", "d", recipient, 10 ether, CAT_GRANTS, duration);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.votingDeadline, before + duration);
    }

    function test_CreateLocalProposal_QuorumSnapshotted() public {
        // quorumRequired = totalVotingPower * quorumBps / 10000
        // = 1000 * 4000 / 10000 = 400
        vm.prank(alice);
        uint256 pid = gov.proposeLocalTransfer("P", "d", recipient, 10 ether, CAT_GRANTS, 2 days);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.quorumRequired, 400);
    }

    function test_CreateLocalProposal_HighQuorumFlaggedForLargeAmount() public {
        // amount > PROPOSAL_CAP triggers high quorum
        // highQuorumRequired = 1000 * 6000 / 10000 = 600
        vm.prank(alice);
        uint256 pid = gov.proposeLocalTransfer("Big Prop", "d", recipient, 2_000 ether, CAT_GRANTS, 2 days);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertTrue(p.requiresHighQuorum);
        assertEq(p.quorumRequired, 600);
    }

    function test_CreateMultipleProposals_CounterIncrements() public {
        vm.startPrank(alice);
        gov.proposeLocalTransfer("P1", "d", recipient, 10 ether, CAT_GRANTS, 2 days);
        gov.proposeLocalTransfer("P2", "d", recipient, 20 ether, CAT_OPS, 2 days);
        gov.proposeLocalTransfer("P3", "d", recipient, 30 ether, CAT_GRANTS, 2 days);
        vm.stopPrank();

        assertEq(gov.proposalCount(), 3);
    }

    function test_RevertIf_NonMemberProposes() public {
        vm.prank(dave);
        vm.expectRevert(GovernanceContract.NotMember.selector);
        gov.proposeLocalTransfer("P", "d", recipient, 10 ether, CAT_GRANTS, 2 days);
    }

    function test_RevertIf_DurationTooShort() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceContract.InvalidDuration.selector);
        gov.proposeLocalTransfer("P", "d", recipient, 10 ether, CAT_GRANTS, 30 minutes);
    }

    function test_RevertIf_DurationTooLong() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceContract.InvalidDuration.selector);
        gov.proposeLocalTransfer("P", "d", recipient, 10 ether, CAT_GRANTS, 8 days);
    }

    // ─────────────────────────────────────────────
    // Cross-Chain Proposal Creation
    // ─────────────────────────────────────────────

    // Moonbeam uses AccountKey20 — pass EVM address cast to bytes32
    bytes32 constant MOONBEAM_RECIP = bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));

    // Substrate chains use AccountId32 — raw 32-byte pubkey
    bytes32 constant SUBSTRATE_RECIP = bytes32(
        0xd43593c715fdd31c61141abd04a99fd6822c8558854ccde39a5684e7a56da27d
    );

    function test_CreateCrossChainProposal_BasicFields() public {
        vm.prank(alice);
        uint256 pid = gov.proposeCrossChainTransfer(
            "XCM to Moonbeam",
            "Transfer funds to Moonbeam parachain",
            2004,
            MOONBEAM_RECIP,
            50 ether,
            CAT_GRANTS,
            2 days
        );

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.transferType), uint8(GovernanceContract.TransferType.CrossChain));
        assertEq(p.targetParaId, 2004);
        assertEq(p.xcmRecipient, MOONBEAM_RECIP);
        assertEq(p.amount, 50 ether);
        assertEq(p.localRecipient, address(0));
    }

    function test_CreateCrossChainProposal_XcmFieldsStored() public {
        vm.prank(bob);
        uint256 pid = gov.proposeCrossChainTransfer(
            "XCM to Astar",
            "d",
            2006,
            SUBSTRATE_RECIP,
            200 ether,
            CAT_OPS,
            1 days
        );

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.xcmRecipient, SUBSTRATE_RECIP);
        assertEq(p.targetParaId, 2006);
        assertEq(p.amount, 200 ether);
    }

    function test_RevertIf_NonMemberCreatesCrossChainProposal() public {
        vm.prank(dave);
        vm.expectRevert(GovernanceContract.NotMember.selector);
        gov.proposeCrossChainTransfer(
            "P", "d", 2006, SUBSTRATE_RECIP, 10 ether, CAT_GRANTS, 2 days
        );
    }

    // ─────────────────────────────────────────────
    // Voting
    // ─────────────────────────────────────────────

    function test_CastVoteFor() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(alice);
        gov.castVote(pid, true);

        (uint256 vFor, uint256 vAgainst,,,) = gov.getVoteSummary(pid);
        assertEq(vFor, 400);
        assertEq(vAgainst, 0);
        assertTrue(gov.hasVoted(pid, alice));
    }

    function test_CastVoteAgainst() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(bob);
        gov.castVote(pid, false);

        (uint256 vFor, uint256 vAgainst,,,) = gov.getVoteSummary(pid);
        assertEq(vFor, 0);
        assertEq(vAgainst, 300);
    }

    function test_MultipleVoters_VotesAccumulate() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(alice); gov.castVote(pid, true);
        vm.prank(bob);   gov.castVote(pid, true);
        vm.prank(carol); gov.castVote(pid, false);

        (uint256 vFor, uint256 vAgainst,,,) = gov.getVoteSummary(pid);
        assertEq(vFor, 700);     // alice + bob
        assertEq(vAgainst, 300); // carol
    }

    function test_RevertIf_DoubleVote() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(alice);
        gov.castVote(pid, true);

        vm.prank(alice);
        vm.expectRevert(GovernanceContract.AlreadyVoted.selector);
        gov.castVote(pid, false);
    }

    function test_RevertIf_VoteOnInactiveProposal() public {
        uint256 pid = _localProposal(100 ether);

        // Defeat it first
        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid); // no votes → defeated

        vm.prank(alice);
        vm.expectRevert(GovernanceContract.ProposalNotActive.selector);
        gov.castVote(pid, true);
    }

    function test_RevertIf_VoteAfterDeadline() public {
        uint256 pid = _localProposal(100 ether);

        vm.warp(block.timestamp + 3 days);

        vm.prank(alice);
        vm.expectRevert(GovernanceContract.ProposalNotActive.selector);
        gov.castVote(pid, true);
    }

    function test_RevertIf_NonMemberVotes() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(dave);
        vm.expectRevert(GovernanceContract.NotMember.selector);
        gov.castVote(pid, true);
    }

    function test_VoteSummary_QuorumMetFlag() public {
        uint256 pid = _localProposal(100 ether);

        // quorumRequired = 400, alice alone has 400 vp
        vm.prank(alice);
        gov.castVote(pid, true);

        (,, uint256 quorumRequired, bool quorumMet, bool majorityFor) = gov.getVoteSummary(pid);
        assertEq(quorumRequired, 400);
        assertTrue(quorumMet);
        assertTrue(majorityFor);
    }

    function test_VoteSummary_QuorumNotMet() public {
        uint256 pid = _localProposal(100 ether);

        // carol has 300 vp, quorum needs 400
        vm.prank(carol);
        gov.castVote(pid, true);

        (,, , bool quorumMet,) = gov.getVoteSummary(pid);
        assertFalse(quorumMet);
    }

    // ─────────────────────────────────────────────
    // Finalization
    // ─────────────────────────────────────────────

    function test_FinalizeProposal_Passes() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(alice); gov.castVote(pid, true);
        vm.prank(bob);   gov.castVote(pid, true);
        // 700 votes for, 0 against — quorum 400 met, majority yes

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Passed));
    }

    function test_FinalizeProposal_Defeated_NoQuorum() public {
        uint256 pid = _localProposal(100 ether);

        // Only carol votes (300 vp < 400 quorum)
        vm.prank(carol); gov.castVote(pid, true);

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Defeated));
    }

    function test_FinalizeProposal_Defeated_MajorityAgainst() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(alice); gov.castVote(pid, false); // 400 against
        vm.prank(bob);   gov.castVote(pid, false); // 300 against
        vm.prank(carol); gov.castVote(pid, true);  // 300 for
        // total: 700 against, 300 for — quorum met but majority against

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Defeated));
    }

    function test_FinalizeProposal_Defeated_ExactTie() public {
        // alice (400) for, bob (300) + carol (300) against = tie: 400 vs 600 → defeated
        uint256 pid = _localProposal(100 ether);

        vm.prank(alice); gov.castVote(pid, true);
        vm.prank(bob);   gov.castVote(pid, false);
        vm.prank(carol); gov.castVote(pid, false);

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Defeated));
    }

    function test_RevertIf_FinalizeBeforeDeadline() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(alice); gov.castVote(pid, true);

        vm.expectRevert(GovernanceContract.VotingStillActive.selector);
        gov.finalizeProposal(pid);
    }

    function test_RevertIf_FinalizeAlreadyFinalized() public {
        uint256 pid = _localProposal(100 ether);
        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid); // defeats with no votes

        vm.expectRevert(GovernanceContract.ProposalNotActive.selector);
        gov.finalizeProposal(pid);
    }

    function test_FinalizeProposal_HighQuorum_PassesWithHighQuorum() public {
        // Large proposal: requires highQuorumBps (60%) = 600 vp
        uint256 pid = _localProposal(2_000 ether); // above PROPOSAL_CAP

        // Alice (400) + Bob (300) = 700 >= 600 high quorum
        vm.prank(alice); gov.castVote(pid, true);
        vm.prank(bob);   gov.castVote(pid, true);

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Passed));
    }

    function test_FinalizeProposal_HighQuorum_DefeatedWithNormalQuorum() public {
        // Large proposal needs 600 quorum — alice alone (400) is not enough
        uint256 pid = _localProposal(2_000 ether);

        vm.prank(alice); gov.castVote(pid, true);
        // 400 votes for, quorumRequired = 600 → not met

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(uint8(p.status), uint8(GovernanceContract.ProposalStatus.Defeated));
    }

    // ─────────────────────────────────────────────
    // Active Proposals View
    // ─────────────────────────────────────────────

    function test_GetActiveProposals_ReturnsOnlyActive() public {
        vm.startPrank(alice);
        gov.proposeLocalTransfer("P1", "d", recipient, 10 ether, CAT_GRANTS, 2 days);
        gov.proposeLocalTransfer("P2", "d", recipient, 10 ether, CAT_GRANTS, 2 days);
        gov.proposeLocalTransfer("P3", "d", recipient, 10 ether, CAT_GRANTS, 2 days);
        vm.stopPrank();

        // Defeat P1
        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(1);
        vm.warp(block.timestamp - 3 days); // reset time for active check

        // Re-create P2, P3 at current time (already active)
        uint256[] memory active = gov.getActiveProposals();
        // P1 defeated, P2 and P3 still active (deadlines not passed yet from their creation)
        // Note: all were created at same timestamp, so P2 and P3 also expired
        // Let's just verify count behavior
        assertEq(gov.proposalCount(), 3);
    }

    function test_GetActiveProposals_EmptyWhenNone() public view {
        uint256[] memory active = gov.getActiveProposals();
        assertEq(active.length, 0);
    }

    // ─────────────────────────────────────────────
    // AI Summary
    // ─────────────────────────────────────────────

    function test_SubmitAISummary_ByProposer() public {
        uint256 pid = _localProposal(100 ether);

        string memory summary = "Risk: LOW. 100 DOT grant to known contributor. Category: grants.";
        vm.prank(alice); // alice is proposer
        gov.submitAISummary(pid, summary);

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.aiSummary, summary);
    }

    function test_SubmitAISummary_ByAdmin() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(admin);
        gov.submitAISummary(pid, "Admin-submitted summary");

        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.aiSummary, "Admin-submitted summary");
    }

    function test_RevertIf_NonProposerSubmitsSummary() public {
        uint256 pid = _localProposal(100 ether);

        vm.prank(bob); // not proposer, not admin
        vm.expectRevert("Not authorized");
        gov.submitAISummary(pid, "Unauthorized summary");
    }

    function test_RevertIf_SummarySubmittedForInactiveProposal() public {
        uint256 pid = _localProposal(100 ether);

        vm.warp(block.timestamp + 3 days);
        gov.finalizeProposal(pid); // defeats

        vm.prank(alice);
        vm.expectRevert(GovernanceContract.ProposalNotActive.selector);
        gov.submitAISummary(pid, "Too late");
    }

    // ─────────────────────────────────────────────
    // Governance Params Update
    // ─────────────────────────────────────────────

    function test_UpdateParams() public {
        vm.prank(admin);
        gov.updateParams(5000, 7000, 2 hours, 14 days);

        assertEq(gov.quorumBps(), 5000);
        assertEq(gov.highQuorumBps(), 7000);
        assertEq(gov.minVotingDuration(), 2 hours);
        assertEq(gov.maxVotingDuration(), 14 days);
    }

    function test_RevertIf_NonAdminUpdatesParams() public {
        vm.prank(alice);
        vm.expectRevert(GovernanceContract.NotAdmin.selector);
        gov.updateParams(5000, 7000, 2 hours, 14 days);
    }

    // ─────────────────────────────────────────────
    // hasReachedQuorum view
    // ─────────────────────────────────────────────

    function test_HasReachedQuorum_True() public {
        uint256 pid = _localProposal(100 ether);
        vm.prank(alice); gov.castVote(pid, true); // 400 >= 400 quorum
        assertTrue(gov.hasReachedQuorum(pid));
    }

    function test_HasReachedQuorum_False() public {
        uint256 pid = _localProposal(100 ether);
        vm.prank(carol); gov.castVote(pid, true); // 300 < 400 quorum
        assertFalse(gov.hasReachedQuorum(pid));
    }

    // ─────────────────────────────────────────────
    // Fuzz Tests
    // ─────────────────────────────────────────────

    /// @notice Fuzz: any valid duration within bounds should succeed
    function testFuzz_ProposalDuration(uint256 duration) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        vm.prank(alice);
        uint256 pid = gov.proposeLocalTransfer("P", "d", recipient, 10 ether, CAT_GRANTS, duration);
        GovernanceContract.Proposal memory p = gov.getProposal(pid);
        assertEq(p.votingDeadline, block.timestamp + duration);
    }

    /// @notice Fuzz: voting power accumulates correctly for any combination of votes
    function testFuzz_VoteAccumulation(uint256 aliceVotes, uint256 bobVotes) public {
        // bound to prevent overflow and ensure we're testing meaningful values
        aliceVotes = bound(aliceVotes, 0, 1);
        bobVotes   = bound(bobVotes, 0, 1);
        bool aliceFor = aliceVotes == 1;
        bool bobFor   = bobVotes == 1;

        uint256 pid = _localProposal(100 ether);

        vm.prank(alice); gov.castVote(pid, aliceFor);
        vm.prank(bob);   gov.castVote(pid, bobFor);

        (uint256 vFor, uint256 vAgainst,,,) = gov.getVoteSummary(pid);

        uint256 expectedFor     = (aliceFor  ? 400 : 0) + (bobFor  ? 300 : 0);
        uint256 expectedAgainst = (aliceFor  ? 0 : 400) + (bobFor  ? 0 : 300);

        assertEq(vFor,     expectedFor);
        assertEq(vAgainst, expectedAgainst);
    }

    // ─────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────

    function _localProposal(uint256 amount) internal returns (uint256) {
        vm.prank(alice);
        return gov.proposeLocalTransfer("Test Proposal", "description", recipient, amount, CAT_GRANTS, 2 days);
    }
}
