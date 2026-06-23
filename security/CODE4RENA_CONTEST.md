# Vortex Protocol — Code4rena Security Contest Brief

## Overview

| Field | Value |
|---|---|
| **Project** | Vortex Protocol (VTX) |
| **Type** | Intent-based cross-chain liquidity router |
| **Prize Pool** | 50,000 VTX (~$50,000 target at launch valuation) |
| **Timeline** | 7 days (exact dates TBD — targeting Q3 2026) |
| **Repo** | https://github.com/Estivalett/vortex-protocol |
| **nSLOC** | ~1,100 lines across 7 contracts |
| **Solidity** | 0.8.24 |
| **Libraries** | OpenZeppelin 5.x |

---

## Prize Distribution

| Severity | Prize |
|---|---|
| 🔴 Critical | 30,000 VTX |
| 🟠 High | 15,000 VTX |
| 🟡 Medium | 5,000 VTX |
| 🔵 Low / Gas | Judged at discretion |

Prizes are paid in VTX from the Community & Incentives allocation (350M VTX pool).  
Multiple findings of the same severity are split proportionally by quality.

---

## Scope

### Contracts IN scope

| Contract | nSLOC | Description |
|---|---|---|
| `contracts/VTX.sol` | ~60 | ERC-20 token — 1B fixed supply, Permit, Votes |
| `contracts/VortexIntent.sol` | ~140 | EIP-712 intent struct, storage, signing |
| `contracts/VortexRouter.sol` | ~260 | Core router — submit, fill, cancel, expire intents |
| `contracts/VortexStaking.sol` | ~230 | Solver staking, revenue distribution, slashing |
| `contracts/VortexGovernor.sol` | ~70 | On-chain governance (Governor + Timelock) |
| `contracts/VortexTimelock.sol` | ~30 | 48-hour governance timelock |
| `contracts/VortexTreasury.sol` | ~120 | Protocol treasury |
| `contracts/VortexVesting.sol` | ~200 | Team/investor vesting (cliff + linear) |

### Out of scope

- External dependencies (OpenZeppelin 5.x) — assumed safe
- Off-chain solver bot (`scripts/solver.js`) — informational only
- Frontend (`frontend/`) — informational only
- Deploy scripts (`scripts/deploy.js`)

---

## Protocol Summary

Vortex Protocol is an intent-based cross-chain liquidity router with competitive solver auctions.

**Flow:**
1. User signs an EIP-712 intent specifying: input token, output token, minimum output, deadline
2. User calls `submitIntent()` — Router pulls input tokens from user
3. Registered solvers (VTX-staked) call `fillIntent()` — first valid solver wins
4. Winning solver delivers output tokens to user; receives input tokens minus 0.05% fee
5. Fee is split: 70% → stakers, 20% → treasury, 10% → operations wallet

**Key invariants:**
- No intent can be filled more than once
- Users can always cancel a PENDING intent and retrieve their input tokens
- Solvers must maintain ≥ 10,000 VTX stake to remain registered
- Stakers always receive ≥ 70% of protocol fees collected by the Router
- All governance changes wait ≥ 48 hours before execution
- `crossChainEnabled` defaults to false — only same-chain intents in V1

---

## Known Issues (Out of Scope for Contest)

The following are acknowledged before the contest and are NOT valid findings:

1. **Cross-chain trust model** — `crossChainEnabled` is false by default. When enabled in future versions, on-chain proof of cross-chain delivery will require a messaging layer integration (LayerZero, Wormhole). Solvers currently operate on trust + slashing collateral.

2. **No maximum slash cap** — Governance can slash 100% of a solver's stake. This is by design (governance-controlled) but acknowledged.

3. **`rewardToken` defaults to `address(0)` (ETH)** — The staking contract accepts ETH rewards via `receive()`. Wardens should check the interplay between ETH rewards and ERC-20 routing fees.

4. **VTX used as reward token** — Using the staking token as reward token is not explicitly prevented. Check for potential accounting issues.

---

## Attack Vectors to Focus On

Wardens are encouraged to investigate (but not limited to):

- **Reentrancy** across the Router → Staking → external token call chain
- **Signature replay** across chains or after protocol version upgrades
- **Reward manipulation** in the accumulator-based distribution model
- **Governance attacks** — flash loan voting, low quorum exploitation
- **Vesting bypass** — early claim vectors in VortexVesting
- **Fee evasion** or economic exploits in the 0.05% fee model
- **Intent front-running** — solver or user griefing vectors
- **Slashing mechanics** — can a solver avoid slashing by front-running the governance tx?
- **Cooldown bypass** — ways to extract staked VTX before the 7-day cooldown

---

## Setup for Local Testing

```bash
git clone https://github.com/Estivalett/vortex-protocol
cd vortex-protocol
npm install
npx hardhat compile
npx hardhat test       # (test suite in progress)
npx hardhat node       # local network
npx hardhat run scripts/deploy.js --network hardhat
```

---

## Contact

- **Email:** hello@vtxprotocol.io
- **Twitter:** @VortexProtocol
- **Discord:** [link TBD]

Questions about scope during the contest period should be directed to the Discord #audit channel.

---

## Judging Criteria

Code4rena standard judging applies. Findings must include:
- Clear description of the vulnerability
- Step-by-step proof of concept (preferably a Hardhat test)
- Impact assessment (likelihood × severity)
- Recommended fix

Duplicate findings receive partial credit based on quality and discovery order.
