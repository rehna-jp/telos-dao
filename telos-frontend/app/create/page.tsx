'use client'

import { useState } from 'react'
import { useWriteContract, useWaitForTransactionReceipt, useAccount, useReadContract, usePublicClient } from 'wagmi'
import { parseEther, keccak256, toBytes, decodeEventLog } from 'viem'
import { GOVERNANCE_ADDRESS, GOVERNANCE_ABI, CATEGORIES } from '@/lib/contracts'
import { useRouter } from 'next/navigation'

interface AISummary {
  summary: string
  riskLevel: string
  riskFactors: string
  recommendation: string
  onChainSummary: string
}

export default function CreateProposalPage() {
  const router = useRouter()
  const { address } = useAccount()
  const publicClient = usePublicClient()

  const [form, setForm] = useState({
    title: '',
    description: '',
    transferType: '0',
    recipient: '',
    targetParaId: '',
    xcmRecipient: '',
    amount: '',
    category: 'grants',
    duration: '2',
    customDuration: '',
  })

  const [aiSummary, setAiSummary] = useState<AISummary | null>(null)
  const [isAnalyzing, setIsAnalyzing] = useState(false)
  const [aiError, setAiError] = useState('')
  const [step, setStep] = useState<'form' | 'ai' | 'submitting' | 'done'>('form')
  const [txStatus, setTxStatus] = useState('')

  const { data: votingPower } = useReadContract({
    address: GOVERNANCE_ADDRESS,
    abi: GOVERNANCE_ABI,
    functionName: 'votingPower',
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  })

  const isMember = votingPower && votingPower > 0n

  const { writeContractAsync: propose } = useWriteContract()
  const { writeContractAsync: submitSummaryAsync } = useWriteContract()

  const categoryKey = form.category as keyof typeof CATEGORIES
  const categoryBytes = CATEGORIES[categoryKey] || keccak256(toBytes(form.category)) as `0x${string}`
const getDurationSeconds = () => {
  const raw = form.duration === 'custom'
    ? parseFloat(form.customDuration || '1')
    : parseFloat(form.duration)

  // values < 1 are treated as fractions of a day, >= 1 as days
  // except the 1hour option which we handle explicitly
  if (form.duration === '0.042') {
    return BigInt(3600) // exactly 1 hour
  }
  if (form.duration === 'custom') {
    return BigInt(Math.floor(raw * 60 * 60)) // custom is in hours
  }
  return BigInt(Math.floor(raw * 24 * 60 * 60)) // dropdown is in days
}

const durationSeconds = getDurationSeconds()
  const handleAnalyze = async () => {
    if (!form.title || !form.description || !form.amount) {
      setAiError('Fill in title, description, and amount first')
      return
    }
    setIsAnalyzing(true)
    setAiError('')
    try {
      const res = await fetch('/api/summarize', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title: form.title,
          description: form.description,
          amount: form.amount,
          recipient: form.recipient,
          category: form.category,
          transferType: parseInt(form.transferType),
          targetParaId: form.targetParaId,
        }),
      })

      const data = await res.json()

      if (!res.ok) {
        setAiError(data.error || `API error ${res.status}`)
        return
      }

      setAiSummary(data)
      setStep('ai')
    } catch (e) {
      setAiError(`Network error: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setIsAnalyzing(false)
    }
  }

  const handleSubmit = async () => {
    if (!address || !publicClient) return
    setStep('submitting')

    try {
      setTxStatus('Submitting proposal...')
      const amount = parseEther(form.amount)
      let txHash: `0x${string}`

      if (form.transferType === '0') {
        txHash = await propose({
          address: GOVERNANCE_ADDRESS,
          abi: GOVERNANCE_ABI,
          functionName: 'proposeLocalTransfer',
          args: [
            form.title,
            form.description,
            form.recipient as `0x${string}`,
            amount,
            categoryBytes,
            durationSeconds,
          ],
        })
      } else {
        // XCM proposal — encode recipient as bytes32
        const rawRecipient = form.xcmRecipient.startsWith('0x')
          ? form.xcmRecipient
          : `0x${form.xcmRecipient}`
        const xcmRecip = rawRecipient.padEnd(66, '0') as `0x${string}`

        txHash = await propose({
          address: GOVERNANCE_ADDRESS,
          abi: GOVERNANCE_ABI,
          functionName: 'proposeCrossChainTransfer',
          args: [
            form.title,
            form.description,
            parseInt(form.targetParaId),
            xcmRecip,
            amount,
            categoryBytes,
            durationSeconds,
          ],
        })
      }

      setTxStatus('Waiting for confirmation...')

      // Wait for receipt and extract proposal ID from ProposalCreated event
      const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash })

      let proposalId: bigint | null = null

      for (const log of receipt.logs) {
        try {
          const decoded = decodeEventLog({
            abi: GOVERNANCE_ABI,
            data: log.data,
            topics: log.topics,
          })
          if (decoded.eventName === 'ProposalCreated') {
            proposalId = (decoded.args as any).proposalId as bigint
            break
          }
        } catch {
          // skip logs that don't match
        }
      }

      if (!proposalId) {
        setTxStatus('Proposal created but could not extract ID. Please submit summary manually.')
        setStep('done')
        return
      }

      // Auto-submit AI summary on-chain
      if (aiSummary) {
        setTxStatus('Storing AI summary on-chain...')
        try {
          const summaryTxHash = await submitSummaryAsync({
            address: GOVERNANCE_ADDRESS,
            abi: GOVERNANCE_ABI,
            functionName: 'submitAISummary',
            args: [proposalId, aiSummary.onChainSummary],
          })
          await publicClient.waitForTransactionReceipt({ hash: summaryTxHash })
          setTxStatus('Done!')
        } catch (summaryErr) {
          console.error('Summary submission failed:', summaryErr)
          setTxStatus('Proposal created. AI summary could not be stored on-chain.')
        }
      }

      setStep('done')
    } catch (e) {
      console.error('Proposal submission failed:', e)
      setAiError(`Transaction failed: ${e instanceof Error ? e.message : String(e)}`)
      setStep('ai')
    }
  }

  const set = (field: string, value: string) => setForm(f => ({ ...f, [field]: value }))

  if (!address) {
    return (
      <div className="empty-state">
        <div className="empty-state-icon">⬡</div>
        <div className="empty-state-title">Connect your wallet</div>
        <p>You need to connect your wallet to create proposals</p>
      </div>
    )
  }

 if (!isMember) {
  return (
    <div className="empty-state">
      <div className="empty-state-icon">🔒</div>
      <div className="empty-state-title">Members only</div>
      <p style={{ marginBottom: '1.5rem' }}>
        Only DAO members can create proposals. Contact the admin to be added.
      </p>
      <p className="mono" style={{ marginBottom: '1.5rem' }}>{address}</p>
      <div style={{ display: 'flex', gap: '0.75rem', justifyContent: 'center' }}>
        <a
          href={`https://blockscout-testnet.polkadot.io/address/${GOVERNANCE_ADDRESS}`}
          target="_blank"
          rel="noopener noreferrer"
          className="btn btn-ghost"
        >
          View Contract ↗
        </a>
        <button className="btn btn-primary" onClick={() => router.push('/')}>
          Browse Proposals →
        </button>
      </div>
    </div>
  )
}

  return (
    <div style={{ maxWidth: 720, margin: '0 auto' }}>
      <div className="page-header">
        <h1 className="page-title">Create <span>Proposal</span></h1>
        <p className="page-subtitle">AI analysis generated automatically before submission</p>
      </div>

      <div className="card">
        {/* Step indicator */}
        <div style={{ display: 'flex', gap: '0.5rem', marginBottom: '1.5rem' }}>
          {['Draft', 'AI Review', 'Submit'].map((s, i) => (
            <div key={s} style={{ display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
              <div style={{
                width: 24, height: 24, borderRadius: '50%', display: 'flex', alignItems: 'center',
                justifyContent: 'center', fontSize: '0.7rem', fontWeight: 700,
                background: step === 'form' && i === 0 ? 'var(--pink)' :
                  step === 'ai' && i === 1 ? 'var(--pink)' :
                  ['submitting', 'done'].includes(step) && i === 2 ? 'var(--green)' : 'var(--bg-3)',
                color: 'white',
              }}>
                {i + 1}
              </div>
              <span style={{ fontSize: '0.75rem', color: 'var(--text-2)', fontFamily: 'var(--font-mono)' }}>{s}</span>
              {i < 2 && <span style={{ color: 'var(--text-3)' }}>→</span>}
            </div>
          ))}
        </div>

        {/* STEP 1: Form */}
        {step === 'form' && (
          <>
            <div className="form-group">
              <label className="form-label">Title</label>
              <input className="form-input" placeholder="Fund protocol development Q2 2026"
                value={form.title} onChange={e => set('title', e.target.value)} />
            </div>

            <div className="form-group">
              <label className="form-label">Description</label>
              <textarea className="form-textarea"
                placeholder="Detailed explanation of what this proposal does and why..."
                value={form.description} onChange={e => set('description', e.target.value)}
                style={{ minHeight: 120 }} />
            </div>

<div style={{ display: 'grid', gridTemplateColumns: 'var(--grid-2, 1fr 2fr)', gap: '1rem' }}
  className="form-grid-2">
                  <div className="form-group">
                <label className="form-label">Transfer Type</label>
                <select className="form-select" value={form.transferType} onChange={e => set('transferType', e.target.value)}>
                  <option value="0">Local (Polkadot Hub)</option>
                  <option value="1">Cross-Chain (XCM)</option>
                </select>
              </div>
              <div className="form-group">
                <label className="form-label">Category</label>
                <select className="form-select" value={form.category} onChange={e => set('category', e.target.value)}>
                  <option value="grants">Grants</option>
                  <option value="operations">Operations</option>
                  <option value="development">Development</option>
                  <option value="marketing">Marketing</option>
                </select>
              </div>
            </div>

            {form.transferType === '0' ? (
              <div className="form-group">
                <label className="form-label">Recipient Address</label>
                <input className="form-input" placeholder="0x..."
                  value={form.recipient} onChange={e => set('recipient', e.target.value)} />
              </div>
            ) : (
              <>
                <div style={{ padding: '0.75rem', background: 'var(--cyan-dim)', border: '1px solid rgba(0,212,255,0.2)', borderRadius: 6, marginBottom: '1rem' }}>
                  <p style={{ fontSize: '0.75rem', color: 'var(--cyan)', fontFamily: 'var(--font-mono)', lineHeight: 1.6 }}>
                    ↗ XCM Cross-Chain Transfer via Polkadot Hub precompile.<br />
                    Moonbeam (2004): pass EVM address as bytes32.<br />
                    Astar (2006), Hydration (2034): pass Substrate pubkey as bytes32.
                  </p>
                </div>
<div style={{ display: 'grid', gridTemplateColumns: 'var(--grid-2, 1fr 2fr)', gap: '1rem' }}
  className="form-grid-2">
                      <div className="form-group">
                    <label className="form-label">Parachain ID</label>
                    <input className="form-input" placeholder="2006"
                      value={form.targetParaId} onChange={e => set('targetParaId', e.target.value)} />
                    <span className="form-hint">2004=Moonbeam 2006=Astar 2034=Hydration</span>
                  </div>
                  <div className="form-group">
                    <label className="form-label">Recipient (bytes32)</label>
                    <input className="form-input" placeholder="0xd43593c715..."
                      value={form.xcmRecipient} onChange={e => set('xcmRecipient', e.target.value)} />
                    <span className="form-hint">32-byte public key or EVM address</span>
                  </div>
                </div>
              </>
            )}

<div style={{ display: 'grid', gridTemplateColumns: 'var(--grid-2, 1fr 2fr)', gap: '1rem' }}
  className="form-grid-2">
                  <div className="form-group">
                <label className="form-label">Amount (WND)</label>
                <input className="form-input" type="number" placeholder="100"
                  value={form.amount} onChange={e => set('amount', e.target.value)} />
              </div>
              <div className="form-group">
  <label className="form-label">Voting Duration</label>
  <select
    className="form-select"
    value={form.duration}
    onChange={e => set('duration', e.target.value)}
  >
    <option value="0.042">1 hour (testing)</option>
    <option value="0.5">12 hours</option>
    <option value="1">1 day</option>
    <option value="2">2 days</option>
    <option value="3">3 days</option>
    <option value="7">7 days</option>
    <option value="custom">Custom...</option>
  </select>
  {form.duration === 'custom' && (
    <input
      className="form-input"
      type="number"
      placeholder="Duration in hours"
      style={{ marginTop: '0.5rem' }}
      onChange={e => set('customDuration', e.target.value)}
    />
  )}
  <span className="form-hint">
    Minimum: 1 hour · Maximum: 7 days
  </span>
</div>
            </div>

            {aiError && (
              <div style={{ padding: '0.75rem', background: 'var(--red-dim)', border: '1px solid rgba(255,77,109,0.2)', borderRadius: 6, marginBottom: '1rem', fontSize: '0.8rem', color: 'var(--red)' }}>
                {aiError}
              </div>
            )}

            <button className="btn btn-primary" onClick={handleAnalyze}
              disabled={isAnalyzing || !form.title || !form.description || !form.amount}
              style={{ width: '100%' }}>
              {isAnalyzing ? (
                <><span className="loading-spinner" style={{ width: 16, height: 16 }} /> Analyzing with AI...</>
              ) : '⬡ Analyze with AI →'}
            </button>
          </>
        )}

        {/* STEP 2: AI Review */}
        {step === 'ai' && aiSummary && (
          <>
            <div className="ai-panel" style={{ marginBottom: '1.5rem' }}>
              <div className="ai-header">
                <div className="ai-dot" />
                <span className="ai-label">AI Analysis Complete</span>
                <span className={`badge badge-${aiSummary.riskLevel.toLowerCase()}`} style={{ marginLeft: 'auto' }}>
                  {aiSummary.riskLevel} RISK
                </span>
              </div>

              <div style={{ marginBottom: '1rem' }}>
                <div style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.4rem', textTransform: 'uppercase', letterSpacing: '0.08em' }}>Summary</div>
                <p style={{ fontSize: '0.875rem', color: 'var(--text)', lineHeight: 1.6 }}>{aiSummary.summary}</p>
              </div>

              {aiSummary.riskFactors && (
                <div style={{ marginBottom: '1rem' }}>
                  <div style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.4rem', textTransform: 'uppercase', letterSpacing: '0.08em' }}>Risk Factors</div>
                  <p style={{ fontSize: '0.8rem', color: 'var(--text-2)', lineHeight: 1.6, whiteSpace: 'pre-line' }}>{aiSummary.riskFactors}</p>
                </div>
              )}

              <div>
                <div style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.4rem', textTransform: 'uppercase', letterSpacing: '0.08em' }}>Recommendation</div>
                <p style={{ fontSize: '0.875rem', fontWeight: 700,
                  color: aiSummary.recommendation.startsWith('APPROVE') ? 'var(--green)' :
                         aiSummary.recommendation.startsWith('REJECT')  ? 'var(--red)'   : 'var(--yellow)' }}>
                  {aiSummary.recommendation}
                </p>
              </div>
            </div>

            <div style={{ background: 'var(--bg-2)', borderRadius: 6, padding: '0.75rem', marginBottom: '1.5rem' }}>
              <div style={{ fontSize: '0.7rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)', marginBottom: '0.25rem' }}>STORED ON-CHAIN AS:</div>
              <p style={{ fontSize: '0.75rem', color: 'var(--text-2)', fontFamily: 'var(--font-mono)', lineHeight: 1.5 }}>
                {aiSummary.onChainSummary}
              </p>
            </div>

            {aiError && (
              <div style={{ padding: '0.75rem', background: 'var(--red-dim)', border: '1px solid rgba(255,77,109,0.2)', borderRadius: 6, marginBottom: '1rem', fontSize: '0.8rem', color: 'var(--red)' }}>
                {aiError}
              </div>
            )}

            <div style={{ display: 'flex', gap: '0.75rem' }}>
              <button className="btn btn-ghost" onClick={() => setStep('form')} style={{ flex: 1 }}>
                ← Edit
              </button>
              <button className="btn btn-primary" onClick={handleSubmit} style={{ flex: 2 }}>
                Submit Proposal On-Chain →
              </button>
            </div>
          </>
        )}

        {/* STEP 3: Submitting */}
        {step === 'submitting' && (
          <div style={{ textAlign: 'center', padding: '3rem 2rem' }}>
            <div style={{ display: 'flex', justifyContent: 'center', marginBottom: '1.5rem' }}>
              <span className="loading-spinner" style={{ width: 40, height: 40, borderWidth: 3 }} />
            </div>
            <div style={{ fontSize: '1rem', fontWeight: 700, marginBottom: '0.5rem' }}>
              {txStatus || 'Processing...'}
            </div>
            <p style={{ fontSize: '0.8rem', color: 'var(--text-3)', fontFamily: 'var(--font-mono)' }}>
              Confirm transactions in MetaMask
            </p>
          </div>
        )}

        {/* STEP 4: Done */}
        {step === 'done' && (
          <div style={{ textAlign: 'center', padding: '2rem' }}>
            <div style={{ fontSize: '3rem', marginBottom: '1rem', color: 'var(--green)' }}>✓</div>
            <div style={{ fontSize: '1.25rem', fontWeight: 800, marginBottom: '0.5rem' }}>Proposal Live</div>
            <p style={{ color: 'var(--text-2)', marginBottom: '0.5rem', fontSize: '0.875rem' }}>
              {txStatus || 'Your proposal and AI analysis are stored on-chain'}
            </p>
            <p style={{ color: 'var(--text-3)', marginBottom: '1.5rem', fontSize: '0.75rem', fontFamily: 'var(--font-mono)' }}>
              Voters can now see the AI risk assessment before voting
            </p>
            <button className="btn btn-primary" onClick={() => router.push('/')}>
              View Dashboard →
            </button>
          </div>
        )}
      </div>
    </div>
  )
}