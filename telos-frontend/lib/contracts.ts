import { parseAbi } from 'viem'

export const GOVERNANCE_ADDRESS = process.env.NEXT_PUBLIC_GOVERNANCE_ADDRESS as `0x${string}`
export const TREASURY_ADDRESS = process.env.NEXT_PUBLIC_TREASURY_ADDRESS as `0x${string}`

export const GOVERNANCE_ABI = parseAbi([
  // Read
  'function proposalCount() view returns (uint256)',
  'function getProposal(uint256 proposalId) view returns ((uint256 id, address proposer, string title, string description, string aiSummary, uint8 transferType, address localRecipient, uint32 targetParaId, bytes32 xcmRecipient, uint256 amount, bytes32 category, uint256 votesFor, uint256 votesAgainst, uint256 votingDeadline, uint256 quorumRequired, uint8 status, bool requiresHighQuorum))',
  'function getActiveProposals() view returns (uint256[])',
  'function getVoteSummary(uint256 proposalId) view returns (uint256 votesFor, uint256 votesAgainst, uint256 quorumRequired, bool quorumMet, bool majorityFor)',
  'function hasVoted(uint256 proposalId, address voter) view returns (bool)',
  'function hasReachedQuorum(uint256 proposalId) view returns (bool)',
  'function votingPower(address member) view returns (uint256)',
  'function totalVotingPower() view returns (uint256)',
  'function quorumBps() view returns (uint256)',
  'function admin() view returns (address)',
  // Write
  'function proposeLocalTransfer(string title, string description, address recipient, uint256 amount, bytes32 category, uint256 votingDuration) returns (uint256)',
  'function proposeCrossChainTransfer(string title, string description, uint32 targetParaId, bytes32 xcmRecipient, uint256 amount, bytes32 category, uint256 votingDuration) returns (uint256)',
  'function castVote(uint256 proposalId, bool support)',
  'function finalizeProposal(uint256 proposalId)',
  'function executeProposal(uint256 proposalId)',
  'function submitAISummary(uint256 proposalId, string summary)',
  // Events
  'event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string title, uint256 amount, uint8 transferType)',
  'event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight)',
  'event ProposalExecuted(uint256 indexed proposalId, uint8 transferType)',
])

export const TREASURY_ABI = parseAbi([
  'function balance() view returns (uint256)',
  'function governance() view returns (address)',
  'function guardian() view returns (address)',
  'function rules() view returns (uint256 proposalCap, bool paused, bool whitelistEnabled)',
  'function isExecuted(uint256 proposalId) view returns (bool)',
  'function canExecute(address recipient, uint256 amount, bytes32 category) view returns (bool ok, string reason)',
  'function assetBalance(uint128 assetId) view returns (uint256)',
])

export const CATEGORIES = {
  grants: '0x70d768e036b28817b6784496950701e008c8ccf4b54e656e0c933a167bd13444' as `0x${string}`,
  operations: '0x9b4b3e5930c67c7c0b3e7c2b8e5f7a3d2c1b8e5f7a3d2c1b8e5f7a3d2c1b8e5' as `0x${string}`,
  development: '0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8' as `0x${string}`,
  marketing: '0x3ac225168df54212a25c1c01fd35bebfea408fdac2e31ddd6f80a4bbf9a5f1cb' as `0x${string}`,
} as const

export const STATUS_LABELS: Record<number, string> = {
  0: 'Active',
  1: 'Passed',
  2: 'Executed',
  3: 'Defeated',
  4: 'Cancelled',
}

export const STATUS_COLORS: Record<number, string> = {
  0: '#00D4FF',
  1: '#00FF88',
  2: '#A78BFA',
  3: '#FF4D6D',
  4: '#6B7280',
}
