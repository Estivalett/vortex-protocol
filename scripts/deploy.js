/**
 * Traverse TRV Protocol — Hardhat Deployment Script
 *
 * Deployment order:
 *   1. TRV token
 *   2. TraverseTimelock
 *   3. TraverseGovernor  (requires TRV + Timelock)
 *   4. TraverseStaking   (requires TRV)
 *   5. TraverseTreasury
 *   6. TraverseRouter    (requires Staking + Treasury)
 *   7. Wire contracts  (setRouter on Staking, etc.)
 *   8. Transfer ownership of Router, Staking, Treasury → Timelock
 *   9. Configure Timelock roles (Governor as proposer, zero as executor)
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying Traverse TRV Protocol...");
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH\n"
  );

  // ─────────────────────────────────────────────────────────────────────────
  // 1. Deploy TRV Token
  // ─────────────────────────────────────────────────────────────────────────
  console.log("1. Deploying TRV token...");
  const TRV = await ethers.getContractFactory("TRV");
  const trv = await TRV.deploy(deployer.address); // full supply → deployer
  await trv.waitForDeployment();
  const vtxAddress = await trv.getAddress();
  console.log("   TRV deployed to:", vtxAddress);

  // ─────────────────────────────────────────────────────────────────────────
  // 2. Deploy TraverseTimelock
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n2. Deploying TraverseTimelock...");
  const TraverseTimelock = await ethers.getContractFactory("TraverseTimelock");

  // Temporary: deployer is proposer during setup; replaced by Governor below.
  const timelockProposers  = [deployer.address];
  // address(0) means anyone can execute after the delay.
  const timelockExecutors  = [ethers.ZeroAddress];
  // Deployer holds admin initially to configure roles, then renounces.
  const timelockAdmin      = deployer.address;

  const timelock = await TraverseTimelock.deploy(
    timelockProposers,
    timelockExecutors,
    timelockAdmin
  );
  await timelock.waitForDeployment();
  const timelockAddress = await timelock.getAddress();
  console.log("   TraverseTimelock deployed to:", timelockAddress);

  // ─────────────────────────────────────────────────────────────────────────
  // 3. Deploy TraverseGovernor
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n3. Deploying TraverseGovernor...");
  const TraverseGovernor = await ethers.getContractFactory("TraverseGovernor");
  const governor = await TraverseGovernor.deploy(vtxAddress, timelockAddress);
  await governor.waitForDeployment();
  const governorAddress = await governor.getAddress();
  console.log("   TraverseGovernor deployed to:", governorAddress);

  // ─────────────────────────────────────────────────────────────────────────
  // 4. Deploy TraverseStaking
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n4. Deploying TraverseStaking...");
  const TraverseStaking = await ethers.getContractFactory("TraverseStaking");
  const staking = await TraverseStaking.deploy(vtxAddress, deployer.address);
  await staking.waitForDeployment();
  const stakingAddress = await staking.getAddress();
  console.log("   TraverseStaking deployed to:", stakingAddress);

  // ─────────────────────────────────────────────────────────────────────────
  // 5. Deploy TraverseTreasury
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n5. Deploying TraverseTreasury...");
  const TraverseTreasury = await ethers.getContractFactory("TraverseTreasury");
  const treasury = await TraverseTreasury.deploy(deployer.address);
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("   TraverseTreasury deployed to:", treasuryAddress);

  // ─────────────────────────────────────────────────────────────────────────
  // 6. Deploy TraverseRouter
  //    Operations wallet: deployer for now (update via governance post-launch)
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n6. Deploying TraverseRouter...");
  const TraverseRouter = await ethers.getContractFactory("TraverseRouter");
  const router = await TraverseRouter.deploy(
    stakingAddress,
    treasuryAddress,
    deployer.address, // opsWallet — replace with multisig post-launch
    deployer.address  // owner    — transferred to Timelock below
  );
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("   TraverseRouter deployed to:", routerAddress);

  // ─────────────────────────────────────────────────────────────────────────
  // 7. Wire Contracts
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n7. Wiring contracts...");

  // Tell Staking which Router is authorised to call distributeRevenue()
  let tx = await staking.setRouter(routerAddress);
  await tx.wait();
  console.log("   Staking.setRouter() done");

  // Rewards are distributed automatically in whatever ERC-20 the Router forwards
  // (each intent's inputToken). No reward-token configuration is required — the
  // Staking contract tracks a per-token accumulator and pays each token on claim.

  // ─────────────────────────────────────────────────────────────────────────
  // 8. Transfer Ownership → Timelock
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n8. Transferring ownership to Timelock...");

  // Ownable2Step: first accept must be called from Timelock side, but for
  // simplicity in this deploy we use transferOwnership (the Timelock inherits
  // TimelockController which can call acceptOwnership via governance if needed).
  // If using Ownable2Step properly, schedule Timelock.acceptOwnership() calls.

  tx = await router.transferOwnership(timelockAddress);
  await tx.wait();
  console.log("   Router ownership transferred to Timelock");

  tx = await staking.transferOwnership(timelockAddress);
  await tx.wait();
  console.log("   Staking ownership transferred to Timelock");

  tx = await treasury.transferOwnership(timelockAddress);
  await tx.wait();
  console.log("   Treasury ownership transferred to Timelock");

  // ─────────────────────────────────────────────────────────────────────────
  // 9. Configure Timelock Roles
  //    - Grant PROPOSER_ROLE to Governor
  //    - Revoke PROPOSER_ROLE from deployer (clean up)
  //    - Revoke TIMELOCK_ADMIN_ROLE from deployer (self-governed from now on)
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n9. Configuring Timelock roles...");

  const PROPOSER_ROLE      = await timelock.PROPOSER_ROLE();
  const CANCELLER_ROLE     = await timelock.CANCELLER_ROLE();
  const TIMELOCK_ADMIN     = await timelock.DEFAULT_ADMIN_ROLE();

  // Grant Governor the proposer and canceller roles
  tx = await timelock.grantRole(PROPOSER_ROLE,  governorAddress);
  await tx.wait();
  console.log("   PROPOSER_ROLE granted to Governor");

  tx = await timelock.grantRole(CANCELLER_ROLE, governorAddress);
  await tx.wait();
  console.log("   CANCELLER_ROLE granted to Governor");

  // Revoke deployer's proposer role
  tx = await timelock.revokeRole(PROPOSER_ROLE, deployer.address);
  await tx.wait();
  console.log("   PROPOSER_ROLE revoked from deployer");

  // Renounce admin role — timelock is now self-governed
  tx = await timelock.renounceRole(TIMELOCK_ADMIN, deployer.address);
  await tx.wait();
  console.log("   TIMELOCK_ADMIN_ROLE renounced by deployer");

  // ─────────────────────────────────────────────────────────────────────────
  // Summary
  // ─────────────────────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════");
  console.log("  Traverse TRV Protocol — Deployment Complete");
  console.log("═══════════════════════════════════════════════");
  console.log("  TRV Token     :", vtxAddress);
  console.log("  Timelock      :", timelockAddress);
  console.log("  Governor      :", governorAddress);
  console.log("  Staking       :", stakingAddress);
  console.log("  Treasury      :", treasuryAddress);
  console.log("  Router        :", routerAddress);
  console.log("═══════════════════════════════════════════════\n");

  // Persist addresses for verification / integration
  const addresses = {
    trv:      vtxAddress,
    timelock: timelockAddress,
    governor: governorAddress,
    staking:  stakingAddress,
    treasury: treasuryAddress,
    router:   routerAddress,
    network:  (await ethers.provider.getNetwork()).name,
    chainId:  Number((await ethers.provider.getNetwork()).chainId),
    deployedAt: new Date().toISOString(),
  };

  const fs = require("fs");
  fs.writeFileSync(
    "./deployments.json",
    JSON.stringify(addresses, null, 2)
  );
  console.log("  Addresses saved to deployments.json");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
