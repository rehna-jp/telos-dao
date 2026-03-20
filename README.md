# ⬡ Telos DAO

> Unified governance for multi-chain treasuries on Polkadot Hub

**Polkadot Solidity Hackathon 2026 · Track 1: EVM Smart Contracts (DeFi + AI)**

---

## What is Telos?

Telos is a decentralized governance protocol that lets DAOs manage and execute treasury decisions across multiple chains from a single, trustless interface — built natively on Polkadot Hub.

Most DAOs hold assets across multiple chains but govern them through siloed, manual processes. A vote passes on one chain, but someone still has to manually bridge and move funds. Telos eliminates that gap.

**The core loop:**
1. A member creates a proposal — AI analyzes it instantly
2. Members vote with weighted voting power
3. Once quorum is reached and voting ends, anyone can finalize
4. Execution is trustless — funds move automatically, locally or cross-chain via XCM

No multisig. No manual bridging. No trusted intermediaries.

---

## Why Polkadot Hub

Polkadot Hub is the first EVM-compatible chain where XCM is a native precompile — not a bolt-on bridge. This means Solidity contracts can dispatch cross-chain messages directly, something impossible on Ethereum or any other EVM chain.

Telos uses three Polkadot-native capabilities:

| Feature | How Telos Uses It |
|---|---|
| XCM Precompile `0x...a0000` | Executes cross-chain treasury transfers after a vote passes |
| Asset Hub Precompile | Queries native DOT/asset balances on-chain |
| SCALE Encoding in Solidity | Correctly encodes XCM messages with AccountId32/AccountKey20 beneficiaries |

---

## Features

- **On-chain governance** — proposals, weighted voting, quorum enforcement, high-quorum for large transfers
- **Spending rules engine** — per-proposal caps, category budgets, recipient whitelisting, emergency pause
- **XCM cross-chain execution** — trustless fund dispatch to any connected parachain after a vote passes
- **AI proposal summarizer** — every proposal is analyzed for risk before going on-chain; the summary is stored permanently in the contract
- **Guardian role** — emergency pause capability without the ability to move funds
- **Full frontend** — dashboard, proposal creation, treasury view, wallet connection via RainbowKit

---

## Architecture
```
GovernanceContract  ──calls──►  TreasuryContract  ──calls──►  XCMHelper
      │                               │                            │
  proposals                      holds funds                 encodes SCALE
  voting                         spending rules              weighs message
  execution trigger              local transfers             executes via precompile
```

### Smart Contracts

| Contract | Address (Polkadot Hub Testnet) |
|---|---|
| `GovernanceContract` | `0x77c264602d531da91E1E1B536Bd10f3609712899` |
| `TreasuryContract` | `0xD143904e8AC65A85eFD5686fC0b11D04924afF4A` |

### Source Files
```
dao-contract/
├── src/
│   ├── GovernanceContract.sol   # proposals, voting, execution trigger
│   ├── TreasuryContract.sol     # asset custody, spending rules, XCM dispatch
│   ├── SpendingRules.sol        # on-chain configurable spending controls (library)
│   ├── XCMHelper.sol            # SCALE encoding, XCM message builder, weight estimation
│   └── interfaces/
│       ├── IXCMPrecompile.sol   # Polkadot Hub XCM precompile interface
│       └── IAssetHub.sol        # Asset Hub precompile interface
├── test/
│   ├── DAOTreasury.t.sol        # integration tests
│   ├── Governance.t.sol         # governance unit tests (50 tests)
│   ├── SpendingRules.t.sol      # spending rules unit tests (31 tests)
│   └── XCMHelper.t.sol          # XCM encoding unit tests (51 tests)
└── script/
    └── Deploy.s.sol             # deployment script

telos-frontend/
├── app/
│   ├── page.tsx                 # proposal dashboard
│   ├── create/page.tsx          # create proposal + AI analysis
│   ├── treasury/page.tsx        # treasury overview
│   └── api/summarize/route.ts  # AI summarizer API route
├── components/
│   ├── Navbar.tsx
│   └── ProposalCard.tsx
└── lib/
    ├── contracts.ts             # ABIs and addresses
    └── wagmi.ts                 # chain config
```

---

## How It Works

### Proposal Lifecycle
```
Member creates proposal
    └─ AI generates risk analysis (stored on-chain)
    └─ Voting opens

Members cast votes (token-weighted)
    └─ quorumRequired snapshotted at creation time
    └─ Large proposals (> proposalCap) require higher quorum

After votingDeadline, anyone calls finalizeProposal()
    └─ Quorum not met OR majority against → Defeated
    └─ Quorum met AND majority for       → Passed

Anyone calls executeProposal()
    └─ Local transfer  → funds sent on Polkadot Hub
    └─ XCM transfer    → XCMHelper builds SCALE message
                         weighMessage() called for dynamic weight
                         execute() dispatches to target parachain
```

### XCM Message Structure

Every cross-chain transfer builds a SCALE-encoded XCM v3 message:
```
WithdrawAsset(DOT, amount)     → pulls from sovereign account
BuyExecution(DOT, Unlimited)   → pays execution fees on destination  
DepositAsset(All, beneficiary) → delivers to recipient
```

Beneficiary encoding is automatic:
- **Moonbeam (paraId 2004)** → `AccountKey20` (EVM address, 24 bytes)
- **All other parachains** → `AccountId32` (Substrate pubkey, 36 bytes)

### Spending Rules

Every transfer is validated before execution:
```
1. paused?              → revert TreasuryPaused
2. amount > cap?        → revert ExceedsProposalCap  
3. not whitelisted?     → revert RecipientNotWhitelisted
4. budget exceeded?     → revert ExceedsCategoryBudget
```

Category budgets reset automatically each period — no manual intervention needed.

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18+
- A funded wallet on Polkadot Hub Testnet

### Smart Contracts
```bash
cd dao-contract

# Install dependencies
forge install foundry-rs/forge-std

# Run tests (168 tests)
forge test -vv

# Deploy to Polkadot Hub Testnet
cp .env.example .env
# fill in PRIVATE_KEY, POLKADOT_HUB_RPC_URL, GUARDIAN_ADDRESS

source .env
forge script script/Deploy.s.sol \
  --rpc-url $POLKADOT_HUB_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url "https://blockscout-testnet.polkadot.io/api" \
  --chain 420420417
```

### Frontend
```bash
cd telos-frontend

# Install dependencies
npm install

# Configure environment
cp .env.local.example .env.local
# fill in API keys and contract addresses

# Run dev server
npm run dev
# opens at http://localhost:3000
```

### Environment Variables

**Smart contracts (`.env`):**
```bash
PRIVATE_KEY=0x...
POLKADOT_HUB_RPC_URL=https://eth-rpc-testnet.polkadot.io
GUARDIAN_ADDRESS=0x...
MEMBER_1=0x...
```

**Frontend (`.env.local`):**
```bash
NEXT_PUBLIC_GOVERNANCE_ADDRESS=0x77c264602d531da91E1E1B536Bd10f3609712899
NEXT_PUBLIC_TREASURY_ADDRESS=0xD143904e8AC65A85eFD5686fC0b11D04924afF4A
NEXT_PUBLIC_CHAIN_ID=420420417
NEXT_PUBLIC_RPC_URL=https://eth-rpc-testnet.polkadot.io
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=...
KIMI_API_KEY=...
```

---

## Network Configuration

| Parameter | Value |
|---|---|
| Network | Polkadot Hub Testnet |
| Chain ID | `420420417` |
| RPC URL | `https://eth-rpc-testnet.polkadot.io` |
| Explorer | `https://blockscout-testnet.polkadot.io` |
| Currency | WND |
| Faucet | `https://faucet.polkadot.io` |

---

## Test Coverage
```
168 tests across 4 test suites — all passing

DAOTreasury.t.sol     36 tests   integration, execution, spending rules
Governance.t.sol      50 tests   proposals, voting, finalization, AI summary
SpendingRules.t.sol   31 tests   caps, budgets, whitelist, period resets
XCMHelper.t.sol       51 tests   SCALE encoding, beneficiary encoding, dispatch
```

---

## Demo Flow

The full demo can be run in under 5 minutes:

1. **Connect** MetaMask to Polkadot Hub Testnet
2. **Create** a proposal — watch AI analyze it in real time
3. **Vote** — see weighted votes and quorum progress update
4. **Finalize** — anyone can call this after the voting period
5. **Execute** — one transaction dispatches funds, locally or cross-chain via XCM

Everything on one screen. No tab switching. No manual steps.

---

## Built With

**Smart Contracts**
- Solidity 0.8.24
- Foundry (build, test, deploy)
- Polkadot Hub XCM Precompile
- Polkadot Hub Asset Hub Precompile

**Frontend**
- Next.js 14 (App Router)
- RainbowKit + wagmi + viem
- Kimi AI (proposal analysis)

---

## Team

Built for the **Polkadot Solidity Hackathon 2026**
Organized by OpenGuild & Web3 Foundation

---

## License

MIT