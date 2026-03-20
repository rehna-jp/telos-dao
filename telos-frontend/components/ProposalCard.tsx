'use client'

import { useState } from 'react'
import { useWriteContract, useWaitForTransactionReceipt, useReadContract, useAccount } from 'wagmi'
import { formatEther } from 'viem'
import { GOVERNANCE_ADDRESS, GOVERNANCE_ABI, STATUS_LABELS } from '@/lib/contracts'

interface Proposal {
  id: bigint
  proposer: string
  title: string
  description: string
  aiSummary: string
  transferType: number
  localRecipient: string
  targetParaId: number
  xcmRecipient: string
  amount: bigint
  category: string
  votesFor: bigint
  votesAgainst: bigint
  votingDeadline: bigint
  quorumRequired: bigint
  status: number
  requiresHighQuorum: boolean
}

export default function ProposalCard({ proposal, onUpdate }: { proposal: Proposal; onUpdate: () => void }) {
  const [expanded, setExpanded] = useState(false)
  const { address } = useAccount()

  const { data: hasVotedData } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'hasVoted',
    args: address ? [proposal.id, address] : undefined,
    query: { enabled: !!address },
  })

  const { data: votingPower } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'votingPower',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

  const { writeContract: castVote, data: voteTxHash, isPending: isVoting } = useWriteContract()
  const { writeContract: finalize, data: finalizeTxHash, isPending: isFinalizing } = useWriteContract()
  const { writeContract: execute, data: executeTxHash, isPending: isExecuting } = useWriteContract()

  const { isLoading: voteConfirming } = useWaitForTransactionReceipt({
    hash: voteTxHash,
    onReplaced: onUpdate,
  })

  const totalVotes = proposal.votesFor + proposal.votesAgainst
  const forPct = totalVotes > 0n ? Number((proposal.votesFor * 100n) / totalVotes) : 0
  const quorumPct = proposal.quorumRequired > 0n
    ? Math.min(100, Number((totalVotes * 100n) / proposal.quorumRequired))
    : 0

  const now = BigInt(Math.floor(Date.now() / 1000))
  const isExpired = now > proposal.votingDeadline
  const timeLeft = proposal.votingDeadline > now
    ? Number(proposal.votingDeadline - now)
    : 0

  const formatTimeLeft = (seconds: number) => {
    if (seconds <= 0) return 'Ended'
    const hours = Math.floor(seconds / 3600)
    const mins = Math.floor((seconds % 3600) / 60)
    if (hours > 24) return `${Math.floor(hours / 24)}d ${hours % 24}h`
    return `${hours}h ${mins}m`
  }

  const statusBadgeClass = ['badge-active', 'badge-passed', 'badge-executed', 'badge-defeated', ''][proposal.status] || 'badge-active'

  const handleVote = (support: boolean) => {
    castVote({
      address: GOVERNANCE_ADDRESS,
      abi: GOVERNANCE_ABI,
      functionName: 'castVote',
      args: [proposal.id, support],
    })
  }

  const handleFinalize = () => {
    finalize({
      address: GOVERNANCE_ADDRESS,
      abi: GOVERNANCE_ABI,
      functionName: 'finalizeProposal',
      args: [proposal.id],
    })
  }

  const handleExecute = () => {
    execute({
      address: GOVERNANCE_ADDRESS,
      abi: GOVERNANCE_ABI,
      functionName: 'executeProposal',
      args: [proposal.id],
    })
  }

  const isMember = votingPower && votingPower > 0n
  const hasVoted = !!hasVotedData

  return (
    <div className="proposal-card" onClick={() => setExpanded(!expanded)}>
      <div className="proposal-card-header">
        <div style={{ flex: 1 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem', marginBottom: '0.5rem' }}>
            <span className={`badge ${statusBadgeClass}`}>
              {STATUS_LABELS[proposal.status]}
            </span>
            {proposal.requiresHighQuorum && (
              <span className="badge badge-medium">High Quorum</span>
            )}
            <span className="badge" style={{ background: 'var(--bg-2)', color: 'var(--text-3)', border: '1px solid var(--border)' }}>
              #{proposal.id.toString()}
            </span>
          </div>
          <div className="proposal-title">{proposal.title}</div>
        </div>
        <div style={{ textAlign: 'right', flexShrink: 0 }}>
          <div style={{ fontSize: '1.25rem', fontWeight: 800, color: 'var(--pink)' }}>
            {parseFloat(formatEther(proposal.amount)).toFixed(2)}
          </div>
          <div style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)' }}>WND</div>
        </div>
      </div>

      <div className="proposal-meta">
        <span className="proposal-meta-item">
          ⏱ {formatTimeLeft(timeLeft)}
        </span>
        <span className="proposal-meta-item">
          {proposal.transferType === 0 ? '⬡ Local' : `↗ XCM Para ${proposal.targetParaId}`}
        </span>
        <span className="proposal-meta-item">
          {proposal.proposer.slice(0, 6)}...{proposal.proposer.slice(-4)}
        </span>
      </div>

      {/* Vote bar */}
      <div style={{ marginBottom: '0.75rem' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.25rem' }}>
          <span style={{ fontSize: '0.75rem', color: 'var(--green)', fontFamily: 'var(--font-mono)', fontWeight: 600 }}>
            FOR {proposal.votesFor.toString()}
          </span>
          <span style={{ fontSize: '0.75rem', color: 'var(--red)', fontFamily: 'var(--font-mono)', fontWeight: 600 }}>
            {proposal.votesAgainst.toString()} AGAINST
          </span>
        </div>
        <div className="vote-bar">
          <div className="vote-bar-for" style={{ width: `${forPct}%` }} />
        </div>
      </div>

      {/* Quorum bar */}
      <div style={{ marginBottom: '1rem' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.25rem' }}>
          <span style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)' }}>
            Quorum
          </span>
          <span style={{ fontSize: '0.7rem', color: quorumPct >= 100 ? 'var(--cyan)' : 'var(--text-3)', fontFamily: 'var(--font-mono)' }}>
            {quorumPct.toFixed(0)}%
          </span>
        </div>
        <div className="quorum-bar">
          <div className="quorum-bar-fill" style={{ width: `${Math.min(100, quorumPct)}%` }} />
        </div>
      </div>

      {/* Expanded content */}
      {expanded && (
        <div onClick={e => e.stopPropagation()}>
          <div className="divider" />

          {proposal.description && (
            <p style={{ fontSize: '0.875rem', color: 'var(--text-2)', lineHeight: 1.6, marginBottom: '1rem' }}>
              {proposal.description}
            </p>
          )}

          {proposal.aiSummary && (
            <div className="ai-panel">
              <div className="ai-header">
                <div className="ai-dot" />
                <span className="ai-label">AI Analysis</span>
              </div>
              <p style={{ fontSize: '0.825rem', color: 'var(--text-2)', lineHeight: 1.6, fontFamily: 'var(--font-mono)' }}>
                {proposal.aiSummary}
              </p>
            </div>
          )}

          <div className="divider" />

          {/* Actions */}
          <div style={{ display: 'flex', gap: '0.75rem', flexWrap: 'wrap' }}>
            {proposal.status === 0 && !isExpired && isMember && !hasVoted && (
              <>
                <button
                  className="btn btn-primary btn-sm"
                  onClick={() => handleVote(true)}
                  disabled={isVoting || voteConfirming}
                >
                  {isVoting || voteConfirming ? <span className="loading-spinner" style={{ width: 14, height: 14 }} /> : null}
                  Vote For
                </button>
                <button
                  className="btn btn-ghost btn-sm"
                  style={{ borderColor: 'rgba(255,77,109,0.3)', color: 'var(--red)' }}
                  onClick={() => handleVote(false)}
                  disabled={isVoting || voteConfirming}
                >
                  Vote Against
                </button>
              </>
            )}

            {proposal.status === 0 && isExpired && (
              <button
                className="btn btn-secondary btn-sm"
                onClick={handleFinalize}
                disabled={isFinalizing}
              >
                {isFinalizing ? <span className="loading-spinner" style={{ width: 14, height: 14 }} /> : null}
                Finalize
              </button>
            )}

            {proposal.status === 1 && (
              <button
                className="btn btn-primary btn-sm"
                onClick={handleExecute}
                disabled={isExecuting}
              >
                {isExecuting ? <span className="loading-spinner" style={{ width: 14, height: 14 }} /> : null}
                Execute
              </button>
            )}

            {hasVoted && proposal.status === 0 && (
              <span style={{ fontSize: '0.8rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', alignSelf: 'center' }}>
                ✓ You voted
              </span>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
