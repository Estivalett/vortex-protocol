/**
 * Vortex Protocol — Solver Bot v1.0
 *
 * Monitors the VortexRouter for pending intents and fills them profitably.
 *
 * Architecture:
 *   1. Listen for IntentCreated events
 *   2. Evaluate each intent for profitability
 *   3. If profitable, check liquidity and fill
 *   4. Claim compensation (netInput) from the Router
 *
 * Usage:
 *   node scripts/solver.js --network base-sepolia
 *   node scripts/solver.js --network hardhat
 *
 * Environment (.env):
 *   SOLVER_PRIVATE_KEY   — private key of the registered solver wallet
 *   RPC_URL              — RPC endpoint (e.g. Alchemy/Infura)
 *   ROUTER_ADDRESS       — VortexRouter contract address
 *   STAKING_ADDRESS      — VortexStaking contract address
 *   MIN_PROFIT_BPS       — minimum profit in bps to fill (default: 10 = 0.10%)
 */

"use strict";

const { ethers } = require("ethers");
require("dotenv").config();

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

const CONFIG = {
  rpcUrl:         process.env.RPC_URL              || "http://127.0.0.1:8545",
  solverKey:      process.env.SOLVER_PRIVATE_KEY   || "",
  routerAddress:  process.env.ROUTER_ADDRESS        || "",
  stakingAddress: process.env.STAKING_ADDRESS       || "",
  minProfitBps:   parseInt(process.env.MIN_PROFIT_BPS || "10"), // 0.10% min profit
  pollIntervalMs: parseInt(process.env.POLL_INTERVAL  || "5000"),
  maxDeadlineSec: 7 * 24 * 3600, // ignore intents expiring in < 30 seconds
};

// ─────────────────────────────────────────────────────────────────────────────
// ABIs (minimal — only functions this bot uses)
// ─────────────────────────────────────────────────────────────────────────────

const ROUTER_ABI = [
  // Events
  "event IntentCreated(bytes32 indexed intentHash, address indexed user, address inputToken, address outputToken, uint256 inputAmount, uint256 minOutput, uint256 sourceChain, uint256 destChain, uint256 deadline, uint256 nonce)",
  "event IntentFilled(bytes32 indexed intentHash, address indexed solver, address indexed user, uint256 actualOutput, uint256 feePaid)",
  "event IntentExpired(bytes32 indexed intentHash, address indexed user)",
  // Read
  "function getIntent(bytes32 intentHash) view returns (tuple(address user, address solver, address inputToken, address outputToken, uint256 inputAmount, uint256 minOutput, uint256 sourceChain, uint256 destChain, uint256 deadline, uint256 nonce, uint8 status))",
  "function computeFee(uint256 inputAmount) pure returns (uint256)",
  "function paused() view returns (bool)",
  // Write
  "function fillIntent(bytes32 intentHash, uint256 actualOutput) nonpayable",
  "function expireIntent(bytes32 intentHash) nonpayable",
];

const STAKING_ABI = [
  "function isSolver(address solver) view returns (bool)",
  "function stake(uint256 amount) nonpayable",
  "function registerAsSolver(uint256 extraStake) nonpayable",
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
];

// ─────────────────────────────────────────────────────────────────────────────
// IntentStatus enum (mirrors Solidity)
// ─────────────────────────────────────────────────────────────────────────────
const IntentStatus = { PENDING: 0, FILLED: 1, CANCELLED: 2, EXPIRED: 3 };

// ─────────────────────────────────────────────────────────────────────────────
// Logging helpers
// ─────────────────────────────────────────────────────────────────────────────
const log  = (...a) => console.log(`[${new Date().toISOString()}]`, ...a);
const warn = (...a) => console.warn(`[${new Date().toISOString()}] ⚠️ `, ...a);
const err  = (...a) => console.error(`[${new Date().toISOString()}] ❌`, ...a);

// ─────────────────────────────────────────────────────────────────────────────
// Global state
// ─────────────────────────────────────────────────────────────────────────────
const seenIntents  = new Set();  // intentHash strings already processed/attempted
const pendingQueue = new Map();  // intentHash → Intent struct

// ─────────────────────────────────────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  log("⚡ Vortex Solver Bot starting...");

  if (!CONFIG.solverKey) {
    err("SOLVER_PRIVATE_KEY not set in .env");
    process.exit(1);
  }
  if (!CONFIG.routerAddress) {
    err("ROUTER_ADDRESS not set in .env — deploy contracts first");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(CONFIG.rpcUrl);
  const signer   = new ethers.Wallet(CONFIG.solverKey, provider);

  log(`Solver wallet: ${signer.address}`);

  // Check network
  const network = await provider.getNetwork();
  log(`Network: ${network.name} (chainId: ${network.chainId})`);

  const router  = new ethers.Contract(CONFIG.routerAddress,  ROUTER_ABI,  signer);
  const staking = new ethers.Contract(CONFIG.stakingAddress, STAKING_ABI, signer);

  // ── Verify solver registration ──────────────────────────────────────────
  await verifySolverRegistration(staking, signer.address);

  // ── Subscribe to IntentCreated events ───────────────────────────────────
  log("Listening for IntentCreated events...");

  router.on("IntentCreated", async (
    intentHash, user, inputToken, outputToken,
    inputAmount, minOutput, sourceChain, destChain, deadline, nonce
  ) => {
    if (seenIntents.has(intentHash)) return;
    seenIntents.add(intentHash);

    const intent = {
      intentHash, user, inputToken, outputToken,
      inputAmount, minOutput, sourceChain, destChain,
      deadline: Number(deadline), nonce, status: IntentStatus.PENDING
    };

    log(`📩 New intent: ${intentHash.slice(0, 10)}... | ${ethers.formatEther(inputAmount)} tokens → min ${ethers.formatEther(minOutput)}`);
    pendingQueue.set(intentHash, intent);
    await tryFillIntent(router, signer, intent);
  });

  router.on("IntentFilled",   (h) => { pendingQueue.delete(h); });
  router.on("IntentExpired",  (h) => { pendingQueue.delete(h); });

  // ── Periodic retry loop ──────────────────────────────────────────────────
  setInterval(async () => {
    const now = Math.floor(Date.now() / 1000);

    for (const [hash, intent] of pendingQueue) {
      if (intent.deadline < now) {
        // Try to expire and collect nothing (clean up for the user)
        await tryExpireIntent(router, hash);
        pendingQueue.delete(hash);
      } else {
        await tryFillIntent(router, signer, intent);
      }
    }
  }, CONFIG.pollIntervalMs);

  log("✅ Solver bot running. Press Ctrl+C to stop.\n");
}

// ─────────────────────────────────────────────────────────────────────────────
// Core: evaluate and fill an intent
// ─────────────────────────────────────────────────────────────────────────────

async function tryFillIntent(router, signer, intent) {
  const now = Math.floor(Date.now() / 1000);

  // Skip if too close to deadline
  if (intent.deadline - now < 30) {
    warn(`Intent ${intent.intentHash.slice(0,10)} expires in <30s, skipping`);
    return;
  }

  try {
    // Re-fetch on-chain status (may have been filled by another solver)
    const onchain = await router.getIntent(intent.intentHash);
    if (onchain.status !== BigInt(IntentStatus.PENDING)) {
      pendingQueue.delete(intent.intentHash);
      return;
    }

    // ── Evaluate profitability ─────────────────────────────────────────────
    const evaluation = await evaluateIntent(signer, intent);

    if (!evaluation.profitable) {
      warn(`Intent ${intent.intentHash.slice(0,10)}: not profitable (${evaluation.reason})`);
      return;
    }

    log(`💰 Filling intent ${intent.intentHash.slice(0,10)} | actualOutput: ${ethers.formatEther(evaluation.actualOutput)}`);

    // ── Approve Router to pull outputToken from solver ─────────────────────
    await ensureApproval(
      signer,
      intent.outputToken,
      router.target,
      evaluation.actualOutput
    );

    // ── Fill ───────────────────────────────────────────────────────────────
    const tx = await router.fillIntent(intent.intentHash, evaluation.actualOutput, {
      gasLimit: 500_000,
    });

    log(`📤 Fill tx sent: ${tx.hash}`);
    const receipt = await tx.wait();
    log(`✅ Intent filled! Gas: ${receipt.gasUsed} | Block: ${receipt.blockNumber}`);

    pendingQueue.delete(intent.intentHash);

  } catch (e) {
    warn(`Failed to fill ${intent.intentHash.slice(0,10)}: ${e.message?.slice(0,120)}`);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Profitability evaluation
//
// For same-chain intents (V1 only), the solver:
//   - Delivers outputToken to the user
//   - Receives netInput (inputToken minus fee)
//   - Profit = netInput * (outputToken/inputToken price) - outputDelivered
//
// For V1, this simplified evaluator assumes same-token swaps (outputToken == inputToken)
// or uses a hardcoded 1:1 ratio as a placeholder for integration with a DEX pricer.
// Production solvers should integrate Uniswap V3 quoter or 1inch for real pricing.
// ─────────────────────────────────────────────────────────────────────────────

async function evaluateIntent(signer, intent) {
  try {
    const inputToken  = new ethers.Contract(intent.inputToken,  ERC20_ABI, signer);
    const outputToken = new ethers.Contract(intent.outputToken, ERC20_ABI, signer);

    // Check solver has enough outputToken to deliver
    const solverOutputBalance = await outputToken.balanceOf(signer.address);
    if (solverOutputBalance < intent.minOutput) {
      return { profitable: false, reason: `insufficient outputToken balance (have ${ethers.formatEther(solverOutputBalance)}, need ${ethers.formatEther(intent.minOutput)})` };
    }

    // Compute what solver receives back
    const FEE_BPS       = 5n;
    const BPS_DENOM     = 10_000n;
    const fee           = (intent.inputAmount * FEE_BPS) / BPS_DENOM;
    const netInput      = intent.inputAmount - fee;

    // ── Price lookup ───────────────────────────────────────────────────────
    // PLACEHOLDER: for same-token (e.g. USDC → USDC same-chain test), 1:1 ratio.
    // In production, replace with:
    //   const quote = await getUniswapV3Quote(intent.outputToken, intent.inputToken, intent.minOutput);
    //   const valueOfNetInput = quote.amountOut;
    const valueOfNetInput = netInput; // 1:1 assumption for testnet

    // Profit = what we receive in inputToken terms - what we deliver in outputToken terms
    // Using minOutput as the cost (we always deliver at least minOutput)
    const actualOutput = intent.minOutput; // deliver exactly the minimum (maximise profit)

    // Estimated profit in inputToken units
    const profit    = valueOfNetInput - actualOutput;
    const profitBps = (profit * 10_000n) / intent.inputAmount;

    if (profitBps < BigInt(CONFIG.minProfitBps)) {
      return {
        profitable: false,
        reason: `profit ${profitBps}bps < minimum ${CONFIG.minProfitBps}bps`
      };
    }

    return {
      profitable:   true,
      actualOutput: actualOutput,
      profit:       profit,
      profitBps:    Number(profitBps),
    };

  } catch (e) {
    return { profitable: false, reason: `evaluation error: ${e.message}` };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function ensureApproval(signer, tokenAddress, spender, amount) {
  const token = new ethers.Contract(tokenAddress, ERC20_ABI, signer);
  const allowance = await token.allowance(signer.address, spender);
  if (allowance < amount) {
    log(`Approving ${spender} for ${ethers.formatEther(amount)} tokens...`);
    const tx = await token.approve(spender, ethers.MaxUint256);
    await tx.wait();
    log("Approval confirmed.");
  }
}

async function tryExpireIntent(router, intentHash) {
  try {
    const tx = await router.expireIntent(intentHash, { gasLimit: 150_000 });
    await tx.wait();
    log(`🧹 Expired intent ${intentHash.slice(0,10)}`);
  } catch (e) {
    // Already expired or filled by someone else — ignore
  }
}

async function verifySolverRegistration(staking, solverAddress) {
  if (!CONFIG.stakingAddress) {
    warn("STAKING_ADDRESS not set — skipping solver registration check");
    return;
  }
  try {
    const registered = await staking.isSolver(solverAddress);
    if (registered) {
      log(`✅ Solver ${solverAddress} is registered in VortexStaking`);
    } else {
      warn(`⚠️  Solver ${solverAddress} is NOT registered.`);
      warn(`    Stake 10,000 VTX and call registerAsSolver() to participate.`);
      warn(`    Bot will continue running but fillIntent() calls will revert.`);
    }
  } catch (e) {
    warn("Could not verify solver registration:", e.message);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

main().catch((e) => {
  err("Fatal error:", e);
  process.exit(1);
});
