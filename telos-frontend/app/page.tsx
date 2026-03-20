'use client'

import { useReadContract, useReadContracts, useAccount } from 'wagmi'
import { GOVERNANCE_ADDRESS, GOVERNANCE_ABI, TREASURY_ADDRESS, TREASURY_ABI } from '@/lib/contracts'
import ProposalCard from '@/components/ProposalCard'
import Link from 'next/link'
import { formatEther } from 'viem'
import { useState, useCallback } from 'react'

export default function DashboardPage() {
  const { address } = useAccount()
  const [refreshKey, setRefreshKey] = useState(0)
  const refresh = useCallback(() => setRefreshKey(k => k + 1), [])

  const { data: proposalCount, isLoading: countLoading } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'proposalCount',
    query: { refetchInterval: 10000 },
  })

  const { data: treasuryBalance } = useReadContract({
    address: TREASURY_ADDRESS,
    abi: TREASURY_ABI,
    functionName: 'balance',
    query: { refetchInterval: 10000 },
  })

  const { data: totalVotingPower } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'totalVotingPower',
  })

  const { data: myVotingPower } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'votingPower',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

  const count = Number(proposalCount || 0)
  const proposalIds = Array.from({ length: count }, (_, i) => BigInt(i + 1))

  const proposalCalls = proposalIds.map(id => ({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'getProposal' as const,
    args: [id] as const,
  }))

  const { data: proposalsData, isLoading: proposalsLoading, refetch } = useReadContracts({
    contracts: proposalCalls,
    query: { enabled: count > 0, refetchInterval: 15000 },
  })

  const proposals = proposalsData
    ?.filter(r => r.status === 'success' && r.result)
    .map(r => r.result as any)
    .reverse() || []

  const activeCount = proposals.filter((p: any) => p.status === 0).length
  const passedCount = proposals.filter((p: any) => p.status === 1).length

  const handleUpdate = () => { refresh(); refetch() }

  const isLoading = countLoading || (count > 0 && proposalsLoading)

  return (
    <div>
      <div className="page-header" style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
        <div>
          <h1 className="page-title">Governance <span>Proposals</span></h1>
          <p className="page-subtitle">Polkadot Hub Testnet · {GOVERNANCE_ADDRESS.slice(0, 10)}...</p>
        </div>
        <Link href="/create" className="btn btn-primary">+ New Proposal</Link>
      </div>

      {/* Stats */}
      <div className="stat-grid">
        <div className="stat-card">
          <div className="stat-label">Treasury</div>
          <div className="stat-value pink">
            {treasuryBalance ? parseFloat(formatEther(treasuryBalance)).toFixed(2) : '—'}
          </div>
          <div style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginTop: '0.25rem' }}>WND</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">Active</div>
          <div className="stat-value cyan">{isLoading ? '—' : activeCount}</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">Passed</div>
          <div className="stat-value green">{isLoading ? '—' : passedCount}</div>
        </div>
        <div className="stat-card">
          <div className="stat-label">Total</div>
          <div className="stat-value">{isLoading ? '—' : count}</div>
        </div>
        {address && myVotingPower !== undefined && (
          <div className="stat-card card-pink">
            <div className="stat-label">Your Power</div>
            <div className="stat-value pink">{myVotingPower.toString()}</div>
            <div style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginTop: '0.25rem' }}>
              of {totalVotingPower?.toString() || '—'} total
            </div>
          </div>
        )}
      </div>

      {/* Loading state */}
      {isLoading && (
        <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem' }}>
          {[1, 2, 3].map(i => (
            <div key={i} className="card" style={{
              height: 140,
              background: 'linear-gradient(90deg, var(--bg-1) 25%, var(--bg-2) 50%, var(--bg-1) 75%)',
              backgroundSize: '200% 100%',
              animation: 'shimmer 1.5s infinite',
            }} />
          ))}
          <style>{`
            @keyframes shimmer {
              0% { background-position: 200% 0; }
              100% { background-position: -200% 0; }
            }
          `}</style>
        </div>
      )}

      {/* Empty state */}
      {!isLoading && count === 0 && (
        <div className="empty-state">
          <div className="empty-state-icon">⬡</div>
          <div className="empty-state-title">No proposals yet</div>
          <p style={{ marginBottom: '1.5rem', fontSize: '0.875rem' }}>
            Be the first to create a governance proposal
          </p>
          <Link href="/create" className="btn btn-primary">Create First Proposal</Link>
        </div>
      )}

      {/* Proposals list */}
      {!isLoading && count > 0 && (
        <div className="proposals-grid">
          {proposals.map((proposal: any) => (
            <ProposalCard
              key={proposal.id.toString()}
              proposal={proposal}
              onUpdate={handleUpdate}
            />
          ))}
        </div>
      )}
    </div>
  )
}