# Vortex Protocol — Immunefi Bug Bounty Program

> **Status:** Active from testnet launch (Q3 2026)
> **Platform:** immunefi.com/bounty/vortex-protocol

---

## Overview

The Vortex Protocol bug bounty program rewards security researchers who responsibly disclose vulnerabilities in our smart contracts. We take security seriously — and we pay competitively.

All rewards are paid in **VTX tokens** from the Community & Incentives pool.

---

## Reward Structure

### Smart Contracts

| Severity | Reward |
|---|---|
| 🔴 Critical | Up to 100,000 VTX |
| 🟠 High | Up to 30,000 VTX |
| 🟡 Medium | Up to 10,000 VTX |
| 🔵 Low | Up to 2,000 VTX |

### Severity Definitions

**Critical** — Direct theft of user funds, permanent freezing of funds, governance takeover, or complete protocol shutdown.

Examples:
- Bypass of ReentrancyGuard leading to fund drain
- Signature forgery bypassing EIP-712 validation
- Governance manipulation leading to treasury drain

**High** — Temporary freezing of funds, theft of unclaimed rewards, or significant economic harm to stakers.

Examples:
- Reward accumulator manipulation
- Solver registration bypass (fill intents without stake)
- Unstake bypass before cooldown expiry

**Medium** — Impact limited to a subset of users or requiring specific conditions to exploit.

Examples:
- Incorrect fee calculation affecting staker rewards
- Intent expiry manipulation that delays user refunds

**Low** — Informational issues, gas optimizations with security implications, or best-practice violations.

---

## Scope

### In Scope

| Asset | Type | Address |
|---|---|---|
| VTX.sol | Smart Contract | TBD (post-mainnet) |
| VortexRouter.sol | Smart Contract | TBD |
| VortexStaking.sol | Smart Contract | TBD |
| VortexGovernor.sol | Smart Contract | TBD |
| VortexTimelock.sol | Smart Contract | TBD |
| VortexTreasury.sol | Smart Contract | TBD |
| VortexVesting.sol | Smart Contract | TBD |

### Out of Scope

- Third-party integrations (OpenZeppelin libraries assumed safe)
- Front-end bugs (phishing, XSS, UI manipulation)
- Issues requiring compromised user keys
- Economic attacks dependent on oracle manipulation (no oracle in V1)
- Griefing attacks with no profit motive for the attacker
- Gas limit issues
- Issues already disclosed in the Code4rena contest report

---

## Disclosure Policy

**Responsible disclosure only.** We ask that:

1. Do NOT publicly disclose a vulnerability before we have confirmed and patched it
2. Submit findings via Immunefi's secure disclosure portal
3. Give us a minimum of 72 hours to respond and 30 days to patch Critical issues
4. Do NOT exploit the vulnerability on mainnet (testnet PoCs are fine)

We commit to:
- Responding within 24 hours to all Critical/High submissions
- Providing a fix timeline within 72 hours of confirming a valid finding
- Crediting researchers (with permission) in our security release notes
- Not pursuing legal action against researchers acting in good faith

---

## Proof of Concept Requirements

All submissions must include:

1. Clear vulnerability description
2. Impact assessment and affected users
3. Step-by-step reproduction instructions
4. Working PoC (Hardhat test preferred):

```bash
git clone https://github.com/Estivalett/vortex-protocol
cd vortex-protocol && npm install
npx hardhat test test/your-poc.js
```

Submissions without a PoC may receive reduced rewards at our discretion.

---

## Hall of Fame

We maintain a public Hall of Fame for researchers who identify and responsibly disclose valid vulnerabilities. All credited researchers receive a special Discord role and are acknowledged in the protocol's security documentation.

---

## Contact

- **Immunefi:** immunefi.com/bounty/vortex-protocol *(link active from Q3 2026)*
- **Direct (Critical only):** security@vtxprotocol.io
- **PGP Key:** available on request

For questions about scope, contact us in Discord `#security` before submitting.
