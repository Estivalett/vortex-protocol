# ⚡ Traverse Protocol (TRV)

> **Conectando liquidez em um único fluxo.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg?logo=solidity)](https://soliditylang.org/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.x-4E5EE4.svg)](https://www.openzeppelin.com/)
[![Built with Hardhat](https://img.shields.io/badge/Built%20with-Hardhat-FFF100.svg)](https://hardhat.org/)
[![CI](https://github.com/DeveloperDefi/traverse-protocol/actions/workflows/test.yml/badge.svg)](https://github.com/DeveloperDefi/traverse-protocol/actions/workflows/test.yml)
[![Status: Testnet](https://img.shields.io/badge/status-testnet-orange.svg)](#-status)

Traverse is a cross-chain liquidity routing protocol with intent-based execution and competitive solver auctions. Users submit signed intents, solvers compete to provide the best execution, and TRV token coordinates the network.

---

## 🔍 What Problem Does Traverse Solve?

Liquidity in DeFi is fragmented across 60+ blockchains and hundreds of DEXs. Users face:
- High slippage from fragmented order books
- Manual bridge complexity
- Poor execution with no competition

**Traverse unifies this into a single flow:** submit an intent, get the best cross-chain execution automatically.

---

## 🏗️ How It Works

```
User → Signs Intent (EIP-712) → Solver Auction → Best Solver Executes → User Receives Tokens
```

1. **User** submits a signed intent: "I want X token on chain Y, minimum Z output"
2. **Solver Network** (TRV-staked entities) compete in a Dutch auction
3. **Winning Solver** executes the cross-chain transaction atomically
4. **Settlement** delivers tokens to user; protocol collects 0.05% fee

---

## 🪙 TRV Token

| Property | Value |
|---|---|
| Standard | ERC-20 + ERC20Permit + ERC20Votes |
| Total Supply | 1,000,000,000 TRV (fixed, no mint) |
| Networks | Base, Arbitrum (launch) → Multi-chain |

**4 Pillars of Utility:**
- **Solver Staking** — Minimum 10,000 TRV to register as solver (slashable collateral)
- **Governance** — 1 TRV = 1 vote; controls fee parameters, treasury, upgrades
- **Fee Discount** — Up to 40% off routing fees by holding TRV
- **Revenue Sharing** — 70% of all protocol fees distributed to stakers

---

## 📁 Repository Structure

```
traverse-protocol/
├── contracts/
│   ├── TRV.sol                # ERC-20 token (fixed 1B supply)
│   ├── TraverseIntent.sol       # Intent structure + EIP-712 signing
│   ├── TraverseRouter.sol       # Core routing + solver competition
│   ├── TraverseStaking.sol      # Staking + revenue distribution
│   ├── TraverseGovernor.sol     # On-chain governance
│   ├── TraverseTimelock.sol     # 48h timelock for governance actions
│   └── TraverseTreasury.sol     # Protocol treasury (governance-controlled)
├── scripts/
│   └── deploy.js              # Hardhat deployment script
├── docs/
│   ├── Traverse_Whitepaper_v1.0.pdf
│   └── Traverse_Tokenomics_VTX.pdf
├── hardhat.config.js
├── package.json
└── README.md
```

---

## 🚀 Getting Started

### Prerequisites

- Node.js 18+
- npm or yarn

### Install Dependencies

```bash
npm install
```

### Configure Environment

```bash
cp .env.example .env
# Fill in your PRIVATE_KEY and RPC URLs
```

### Compile Contracts

```bash
npm run compile
```

### Run Tests

```bash
npm test
```

### Deploy to Testnet (Base Sepolia)

```bash
npm run deploy:base-sepolia
```

### Deploy to Mainnet

```bash
npm run deploy:base
```

---

## 🔐 Security

- All contracts use OpenZeppelin 5.x audited libraries
- ReentrancyGuard on all state-changing external functions
- Checks-Effects-Interactions pattern throughout
- 48-hour Timelock on all governance actions
- 4/7 Multisig on treasury (Safe)
- Independent audit required before mainnet

> ⚠️ **These contracts are unaudited. Do not use in production without a full security audit.**

---

## 📊 Tokenomics

| Category | % | TRV | Cliff | Vesting |
|---|---|---|---|---|
| Community & Incentives | 35% | 350,000,000 | — | 4 years gradual |
| Team & Founders | 18% | 180,000,000 | 12 months | 36 months linear |
| Seed Investors | 8% | 80,000,000 | 6 months | 24 months linear |
| Series A | 7% | 70,000,000 | 3 months | 18 months linear |
| Protocol Treasury | 20% | 200,000,000 | — | Governance-controlled |
| Initial Liquidity (DEX) | 7% | 70,000,000 | — | Locked 12 months |
| Airdrop & Early Users | 5% | 50,000,000 | 1 month | 6 months linear |

**Fee Distribution:** 0.05% of routed volume → 70% stakers / 20% treasury / 10% operations

---

## 🗺️ Roadmap

| Quarter | Milestone |
|---|---|
| Q3 2026 | Public testnet · Bug bounty · Independent audit |
| Q4 2026 | Mainnet (Base + Arbitrum) · DEX launch · Airdrop |
| Q1–Q2 2027 | Solana + BSC expansion · $100M+ monthly volume |
| Q3–Q4 2027 | CEX listings · Protocol V2 · Global expansion |

---

## ⚖️ Competitive Landscape

| Feature | Traverse ✓ | 1inch | Jupiter | LiFi | CoW |
|---|---|---|---|---|---|
| Native cross-chain | ✓ | Partial | ✗ | ✓ | ✗ |
| Solver competition | ✓ | ✗ | ✗ | ✗ | ✓ |
| Intent-based | ✓ | ✗ | ✗ | ✗ | ✓ |
| Multi-chain launch | ✓ | ✗ | Solana only | ✓ | ✗ |
| TRV revenue sharing | ✓ | ✗ | ✗ | ✗ | Partial |

---

## 📄 Documentation

- [Whitepaper v1.0](docs/Traverse_Whitepaper_v1.0.pdf)
- [Tokenomics](docs/Traverse_Tokenomics_VTX.pdf)

---

## ⚠️ Disclaimer

This repository is for informational and development purposes only. TRV tokens represent utility and governance rights within the Traverse Protocol. Nothing in this repository constitutes financial, legal, or investment advice. Investments in digital assets carry substantial risk including total loss of capital. Consult qualified legal and financial advisors before making any investment decisions.

---

## 📬 Contact

- Website: [traverseprotocol.io](https://traverseprotocol.io) *(coming soon)*
- Email: hello@traverseprotocol.io
- Twitter: [@TRVprotocol](https://twitter.com/TRVprotocol)

---

*Built with ❤️ by the Traverse Protocol team*
