'use client'

import { useReadContract } from 'wagmi'
import { formatEther } from 'viem'
import { TREASURY_ADDRESS, TREASURY_ABI, GOVERNANCE_ADDRESS, GOVERNANCE_ABI } from '@/lib/contracts'

export default function TreasuryPage() {
  const { data: balance } = useReadContract({
    address: TREASURY_ADDRESS,
    abi: TREASURY_ABI,
    functionName: 'balance',
    query: { refetchInterval: 10000 },
  })

  const { data: rules } = useReadContract({
    address: TREASURY_ADDRESS,
    abi: TREASURY_ABI,
    functionName: 'rules',
  })

  const { data: governance } = useReadContract({
    address: TREASURY_ADDRESS,
    abi: TREASURY_ABI,
    functionName: 'governance',
  })

  const { data: guardian } = useReadContract({
    address: TREASURY_ADDRESS,
    abi: TREASURY_ABI,
    functionName: 'guardian',
  })

  const { data: totalVotingPower } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'totalVotingPower',
  })

  const { data: quorumBps } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'quorumBps',
  })

  const { data: proposalCount } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'proposalCount',
  })

  const proposalCap = rules ? rules[0] : 0n
  const isPaused = rules ? rules[1] : false
  const whitelistEnabled = rules ? rules[2] : false

  return (
    <div>
      <div className="page-header">
        <h1 className="page-title">
          Treasury <span>Overview</span>
        </h1>
        <p className="page-subtitle">
          {TREASURY_ADDRESS.slice(0, 10)}...{TREASURY_ADDRESS.slice(-8)}
        </p>
      </div>

      {/* Main balance */}
      <div className="card card-pink" style={{ marginBottom: '1.5rem', textAlign: 'center', padding: '2.5rem' }}>
        <div style={{ fontSize: '0.7rem', fontFamily: 'var(--font-mono)', color: 'var(--text-3)', letterSpacing: '0.1em', textTransform: 'uppercase', marginBottom: '0.5rem' }}>
          Treasury Balance
        </div>
        <div style={{ fontSize: '3.5rem', fontWeight: 800, letterSpacing: '-0.04em', color: 'var(--pink)', lineHeight: 1 }}>
          {balance ? parseFloat(formatEther(balance)).toFixed(4) : '—'}
        </div>
        <div style={{ fontSize: '1rem', color: 'var(--text-2)', marginTop: '0.5rem', fontFamily: 'var(--font-mono)' }}>WND</div>

        {isPaused && (
          <div style={{ marginTop: '1rem', padding: '0.5rem 1rem', background: 'var(--red-dim)', border: '1px solid rgba(255,77,109,0.3)', borderRadius: 6, display: 'inline-block' }}>
            <span style={{ color: 'var(--red)', fontSize: '0.8rem', fontWeight: 700 }}>⚠ Treasury Paused</span>
          </div>
        )}
      </div>

<div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '1rem', marginBottom: '1.5rem' }}
  className="form-grid-2">
            {/* Governance info */}
        <div className="card">
          <div style={{ fontSize: '0.7rem', fontFamily: 'var(--font-mono)', color: 'var(--text-3)', letterSpacing: '0.1em', textTransform: 'uppercase', marginBottom: '1rem' }}>
            Governance
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
            <div>
              <div style={{ fontSize: '0.65rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.2rem' }}>TOTAL PROPOSALS</div>
              <div style={{ fontSize: '1.5rem', fontWeight: 800, color: 'var(--cyan)' }}>{proposalCount?.toString() || '0'}</div>
            </div>
            <div>
              <div style={{ fontSize: '0.65rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.2rem' }}>TOTAL VOTING POWER</div>
              <div style={{ fontSize: '1.5rem', fontWeight: 800 }}>{totalVotingPower?.toString() || '—'}</div>
            </div>
            <div>
              <div style={{ fontSize: '0.65rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.2rem' }}>QUORUM REQUIRED</div>
              <div style={{ fontSize: '1.5rem', fontWeight: 800, color: 'var(--pink)' }}>
                {quorumBps ? `${Number(quorumBps) / 100}%` : '—'}
              </div>
            </div>
          </div>
        </div>

        {/* Spending rules */}
        <div className="card">
          <div style={{ fontSize: '0.7rem', fontFamily: 'var(--font-mono)', color: 'var(--text-3)', letterSpacing: '0.1em', textTransform: 'uppercase', marginBottom: '1rem' }}>
            Spending Rules
          </div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
            <div>
              <div style={{ fontSize: '0.65rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.2rem' }}>PROPOSAL CAP</div>
              <div style={{ fontSize: '1.25rem', fontWeight: 800 }}>
                {proposalCap ? `${parseFloat(formatEther(proposalCap)).toFixed(0)} WND` : '—'}
              </div>
            </div>
            <div style={{ display: 'flex', gap: '0.5rem', flexWrap: 'wrap' }}>
              <span className={`badge ${isPaused ? 'badge-defeated' : 'badge-passed'}`}>
                {isPaused ? 'PAUSED' : 'ACTIVE'}
              </span>
              <span className={`badge ${whitelistEnabled ? 'badge-medium' : 'badge-active'}`}>
                {whitelistEnabled ? 'WHITELIST ON' : 'OPEN'}
              </span>
            </div>
          </div>
        </div>
      </div>

      {/* Contract addresses */}
      <div className="card">
        <div style={{ fontSize: '0.7rem', fontFamily: 'var(--font-mono)', color: 'var(--text-3)', letterSpacing: '0.1em', textTransform: 'uppercase', marginBottom: '1rem' }}>
          Contract Addresses
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
          {[
            { label: 'TREASURY', address: TREASURY_ADDRESS },
            { label: 'GOVERNANCE', address: GOVERNANCE_ADDRESS },
            { label: 'GOVERNANCE CONTRACT', address: governance as string },
            { label: 'GUARDIAN', address: guardian as string },
          ].map(({ label, address }) => address && (
            <div key={label} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', letterSpacing: '0.08em' }}>
                {label}
              </span>
              <a
                href={`https://blockscout-testnet.polkadot.io/address/${address}`}
                target="_blank"
                rel="noopener noreferrer"
                style={{ fontSize: '0.75rem', color: 'var(--cyan)', fontFamily: 'var(--font-mono)', textDecoration: 'none' }}
              >
                {address.slice(0, 10)}...{address.slice(-8)} ↗
              </a>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
