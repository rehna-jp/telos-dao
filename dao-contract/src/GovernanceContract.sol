// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TreasuryContract} from "./TreasuryContract.sol";
import {SpendingRules} from "./SpendingRules.sol";

/// @title GovernanceContract
/// @notice On-chain DAO governance for multi-chain treasury management on Polkadot Hub
/// @dev Proposals can trigger local transfers or XCM cross-chain execution
contract GovernanceContract {

    // ─────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────
    error NotMember();
    error AlreadyVoted();
    error ProposalNotActive();
    error ProposalNotPassed();
    error ProposalAlreadyExecuted();
    error VotingStillActive();
    error QuorumNotReached();
    error InvalidDuration();
    error ZeroAddress();
    error AlreadyMember();
    error NotAdmin();

    // ─────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────

    enum ProposalStatus {
        Active,     // Voting ongoing
        Passed,     // Quorum + majority reached, awaiting execution
        Executed,   // Transfer dispatched
        Defeated,   // Failed to reach quorum or majority
        Cancelled   // Cancelled by admin
    }

    enum TransferType {
        Local,       // Same-chain transfer on Polkadot Hub
        CrossChain   // XCM transfer to a parachain
    }

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        string aiSummary;        // Populated off-chain, stored on-chain for transparency
        // Transfer details
        TransferType transferType;
        address localRecipient;  // For local transfers
        uint32 targetParaId;     // For XCM transfers
        bytes32 xcmRecipient;    // AccountId32 of recipient on target chain
        uint256 amount;
        bytes32 category;        // Spending category (e.g. keccak256("grants"))
        // Voting
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 votingDeadline;
        uint256 quorumRequired; // Snapshot of quorum at proposal time
        ProposalStatus status;
        bool requiresHighQuorum; // True if amount exceeds proposalCap
    }

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 amount,
        TransferType transferType
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId, TransferType transferType);
    event ProposalDefeated(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event AISummarySubmitted(uint256 indexed proposalId, string summary);
    event MemberAdded(address indexed member, uint256 votingPower);
    event MemberRemoved(address indexed member);
    event GovernanceParamsUpdated(uint256 quorumBps, uint256 minVotingDuration, uint256 maxVotingDuration);

    // ─────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────

    /// @notice The treasury this governance controls
    TreasuryContract public immutable treasury;

    /// @notice Admin — can add/remove members and update params (should be renounced post-setup)
    address public admin;

    /// @notice Voting power per member
    mapping(address => uint256) public votingPower;

    /// @notice Total voting power across all members
    uint256 public totalVotingPower;

    /// @notice All proposals
    mapping(uint256 => Proposal) public proposals;

    /// @notice Vote record — proposalId => voter => voted
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /// @notice Proposal counter
    uint256 public proposalCount;

    /// @notice Quorum in basis points (e.g. 4000 = 40% of total voting power)
    uint256 public quorumBps;

    /// @notice High quorum in bps — required for proposals exceeding the proposal cap
    uint256 public highQuorumBps;

    /// @notice Minimum and maximum voting duration in seconds
    uint256 public minVotingDuration;
    uint256 public maxVotingDuration;

    // ─────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────

    modifier onlyMember() {
        if (votingPower[msg.sender] == 0) revert NotMember();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ─────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────

    /// @param _treasury Address of the TreasuryContract
    /// @param _quorumBps Quorum in basis points (e.g. 4000 = 40%)
    /// @param _highQuorumBps High quorum for large proposals (e.g. 6000 = 60%)
    /// @param _minVotingDuration Minimum voting period in seconds
    /// @param _maxVotingDuration Maximum voting period in seconds
    constructor(
        address _treasury,
        uint256 _quorumBps,
        uint256 _highQuorumBps,
        uint256 _minVotingDuration,
        uint256 _maxVotingDuration
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = TreasuryContract(payable(_treasury));
        admin = msg.sender;
        quorumBps = _quorumBps;
        highQuorumBps = _highQuorumBps;
        minVotingDuration = _minVotingDuration;
        maxVotingDuration = _maxVotingDuration;
    }

    // ─────────────────────────────────────────────
    // Proposals
    // ─────────────────────────────────────────────

    /// @notice Create a local transfer proposal
    /// @param title Short title
    /// @param description Full description
    /// @param recipient Recipient on Polkadot Hub
    /// @param amount Amount in native DOT (wei)
    /// @param category Spending category
    /// @param votingDuration Duration in seconds
    function proposeLocalTransfer(
        string calldata title,
        string calldata description,
        address recipient,
        uint256 amount,
        bytes32 category,
        uint256 votingDuration
    ) external onlyMember returns (uint256 proposalId) {
        _validateDuration(votingDuration);

        proposalId = ++proposalCount;
        (uint256 cap,,) = treasury.rules();
        bool highQuorum = amount > cap;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            aiSummary: "",
            transferType: TransferType.Local,
            localRecipient: recipient,
            targetParaId: 0,
            xcmRecipient: bytes32(0),
            amount: amount,
            category: category,
            votesFor: 0,
            votesAgainst: 0,
            votingDeadline: block.timestamp + votingDuration,
            quorumRequired: highQuorum
                ? (totalVotingPower * highQuorumBps) / 10000
                : (totalVotingPower * quorumBps) / 10000,
            status: ProposalStatus.Active,
            requiresHighQuorum: highQuorum
        });

        emit ProposalCreated(proposalId, msg.sender, title, amount, TransferType.Local);
    }

    /// @notice Create a cross-chain XCM transfer proposal
    /// @param title Short title
    /// @param description Full description
    /// @param targetParaId Destination parachain ID (e.g. 2004 = Moonbeam, 2006 = Astar)
    /// @param xcmRecipient 32-byte AccountId32 public key of the recipient on the target chain
    /// @param amount Amount in planck (1 DOT = 10_000_000_000 planck)
    /// @param category Spending category
    /// @param votingDuration Duration in seconds
    function proposeCrossChainTransfer(
        string calldata title,
        string calldata description,
        uint32 targetParaId,
        bytes32 xcmRecipient,
        uint256 amount,
        bytes32 category,
        uint256 votingDuration
    ) external onlyMember returns (uint256 proposalId) {
        _validateDuration(votingDuration);

        proposalId = ++proposalCount;
        (uint256 cap,,) = treasury.rules();
        bool highQuorum = amount > cap;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            title: title,
            description: description,
            aiSummary: "",
            transferType: TransferType.CrossChain,
            localRecipient: address(0),
            targetParaId: targetParaId,
            xcmRecipient: xcmRecipient,
            amount: amount,
            category: category,
            votesFor: 0,
            votesAgainst: 0,
            votingDeadline: block.timestamp + votingDuration,
            quorumRequired: highQuorum
                ? (totalVotingPower * highQuorumBps) / 10000
                : (totalVotingPower * quorumBps) / 10000,
            status: ProposalStatus.Active,
            requiresHighQuorum: highQuorum
        });

        emit ProposalCreated(proposalId, msg.sender, title, amount, TransferType.CrossChain);
    }

    // ─────────────────────────────────────────────
    // Voting
    // ─────────────────────────────────────────────

    /// @notice Cast a vote on an active proposal
    /// @param proposalId The proposal to vote on
    /// @param support True = For, False = Against
    function castVote(uint256 proposalId, bool support) external onlyMember {
        Proposal storage p = proposals[proposalId];

        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.timestamp > p.votingDeadline) revert ProposalNotActive();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        hasVoted[proposalId][msg.sender] = true;
        uint256 weight = votingPower[msg.sender];

        if (support) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    // ─────────────────────────────────────────────
    // Finalization & Execution
    // ─────────────────────────────────────────────

    /// @notice Finalize a proposal after voting ends — marks as Passed or Defeated
    /// @dev Anyone can call this after the deadline
    function finalizeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.timestamp <= p.votingDeadline) revert VotingStillActive();

        uint256 totalVotes = p.votesFor + p.votesAgainst;

        if (totalVotes < p.quorumRequired || p.votesFor <= p.votesAgainst) {
            p.status = ProposalStatus.Defeated;
            emit ProposalDefeated(proposalId);
        } else {
            p.status = ProposalStatus.Passed;
        }
    }

    /// @notice Execute a passed proposal — dispatches the transfer
    /// @dev Anyone can call this once a proposal has Passed status
    function executeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        if (p.status != ProposalStatus.Passed) revert ProposalNotPassed();

        p.status = ProposalStatus.Executed;

        if (p.transferType == TransferType.Local) {
            treasury.executeLocalTransfer(
                proposalId,
                p.localRecipient,
                p.amount,
                p.category
            );
        } else {
            treasury.executeCrossChainTransfer(
                proposalId,
                p.targetParaId,
                p.xcmRecipient,
                p.amount,
                p.category
            );
        }

        emit ProposalExecuted(proposalId, p.transferType);
    }

    // ─────────────────────────────────────────────
    // AI Summary (transparency layer)
    // ─────────────────────────────────────────────

    /// @notice Submit an AI-generated summary for a proposal
    /// @dev Called by the proposer or a designated relayer after off-chain AI processing
    /// @dev Summary is stored on-chain for full transparency — anyone can verify
    function submitAISummary(uint256 proposalId, string calldata summary) external {
        Proposal storage p = proposals[proposalId];
        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        // Only proposer or admin can submit
        require(msg.sender == p.proposer || msg.sender == admin, "Not authorized");
        p.aiSummary = summary;
        emit AISummarySubmitted(proposalId, summary);
    }

    // ─────────────────────────────────────────────
    // Admin — member management
    // ─────────────────────────────────────────────

    /// @notice Add a DAO member with voting power
    function addMember(address member, uint256 power) external onlyAdmin {
        if (votingPower[member] > 0) revert AlreadyMember();
        if (member == address(0)) revert ZeroAddress();
        votingPower[member] = power;
        totalVotingPower += power;
        emit MemberAdded(member, power);
    }

    /// @notice Remove a DAO member
    function removeMember(address member) external onlyAdmin {
        uint256 power = votingPower[member];
        if (power == 0) revert NotMember();
        totalVotingPower -= power;
        delete votingPower[member];
        emit MemberRemoved(member);
    }

    /// @notice Update governance parameters
    function updateParams(
        uint256 _quorumBps,
        uint256 _highQuorumBps,
        uint256 _minDuration,
        uint256 _maxDuration
    ) external onlyAdmin {
        quorumBps = _quorumBps;
        highQuorumBps = _highQuorumBps;
        minVotingDuration = _minDuration;
        maxVotingDuration = _maxDuration;
        emit GovernanceParamsUpdated(_quorumBps, _minDuration, _maxDuration);
    }

    // ─────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────

    /// @notice Get the current state of a proposal
    function getProposal(uint256 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    /// @notice Get all active proposal IDs
    function getActiveProposals() external view returns (uint256[] memory) {
        uint256 count;
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].status == ProposalStatus.Active) count++;
        }
        uint256[] memory ids = new uint256[](count);
        uint256 idx;
        for (uint256 i = 1; i <= proposalCount; i++) {
            if (proposals[i].status == ProposalStatus.Active) ids[idx++] = i;
        }
        return ids;
    }

    /// @notice Check if a proposal has reached quorum
    function hasReachedQuorum(uint256 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return (p.votesFor + p.votesAgainst) >= p.quorumRequired;
    }

    /// @notice Preview vote outcome for a proposal
    function getVoteSummary(uint256 proposalId)
        external
        view
        returns (
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 quorumRequired,
            bool quorumMet,
            bool majorityFor
        )
    {
        Proposal storage p = proposals[proposalId];
        uint256 total = p.votesFor + p.votesAgainst;
        return (
            p.votesFor,
            p.votesAgainst,
            p.quorumRequired,
            total >= p.quorumRequired,
            p.votesFor > p.votesAgainst
        );
    }

    // ─────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────

    function _validateDuration(uint256 duration) internal view {
        if (duration < minVotingDuration || duration > maxVotingDuration) {
            revert InvalidDuration();
        }
    }
}
