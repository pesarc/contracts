#!/usr/bin/env node
/**
 * Pesarc SVM devnet bootstrap — makes the deployed programs LIVE (not just
 * deployed bytecode) by creating their one-time singleton state:
 *
 *   realized_rate_oracle.initialize()            -> config PDA
 *   realized_rate_oracle.set_recorder(deployer)  -> lets deployer/agent record realized rates
 *   prediction_market.initialize(treasury, fee)  -> config PDA (treasury = deployer, 1% fee)
 *
 * Idempotent: an already-initialized singleton is detected and skipped, so this
 * is safe to re-run. Markets themselves are created later (app UI / a seed step),
 * each carrying its own oracle pair (token_in/token_out) at creation time.
 *
 * Run (from anywhere; uses the app's anchor client):
 *   NODE_PATH=/Users/Apple/Code/pesarc/app/node_modules \
 *     node /Users/Apple/Code/pesarc/contracts/svm/scripts/bootstrap-devnet.cjs
 *
 * Uses the Solana CLI's configured keypair (~/.config/solana/id.json) on devnet.
 */
const os = require("os");
const fs = require("fs");
const path = require("path");
const anchor = require("@coral-xyz/anchor");
const { PublicKey, Connection, Keypair } = anchor.web3;

const RPC = process.env.SVM_RPC_URL || "https://api.devnet.solana.com";
const IDL_DIR = path.resolve(__dirname, "..", "target", "idl");

function loadKeypair() {
  const p = process.env.SOLANA_KEYPAIR || path.join(os.homedir(), ".config/solana/id.json");
  const secret = JSON.parse(fs.readFileSync(p, "utf8"));
  return Keypair.fromSecretKey(Uint8Array.from(secret));
}

async function accountExists(conn, pubkey) {
  const info = await conn.getAccountInfo(pubkey);
  return Boolean(info);
}

async function main() {
  const kp = loadKeypair();
  const conn = new Connection(RPC, "confirmed");
  const wallet = new anchor.Wallet(kp);
  const provider = new anchor.AnchorProvider(conn, wallet, { commitment: "confirmed" });
  anchor.setProvider(provider);

  const bal = await conn.getBalance(wallet.publicKey);
  console.log("deployer:", wallet.publicKey.toBase58(), "| balance:", (bal / 1e9).toFixed(4), "SOL");

  const oracleIdl = require(path.join(IDL_DIR, "realized_rate_oracle.json"));
  const marketIdl = require(path.join(IDL_DIR, "prediction_market.json"));
  const oracle = new anchor.Program(oracleIdl, provider);
  const market = new anchor.Program(marketIdl, provider);
  console.log("oracle program:", oracle.programId.toBase58());
  console.log("market program:", market.programId.toBase58());

  // --- oracle.initialize (config PDA [b"config"]) ---
  const [oracleConfig] = PublicKey.findProgramAddressSync([Buffer.from("config")], oracle.programId);
  if (await accountExists(conn, oracleConfig)) {
    console.log("• oracle config already initialized:", oracleConfig.toBase58());
  } else {
    const sig = await oracle.methods.initialize().accounts({ authority: wallet.publicKey }).rpc();
    console.log("✓ oracle.initialize:", oracleConfig.toBase58(), "| tx", sig);
  }

  // --- oracle.set_recorder(deployer, true) (recorder PDA [b"recorder", deployer]) ---
  const [recorderPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("recorder"), wallet.publicKey.toBuffer()],
    oracle.programId
  );
  if (await accountExists(conn, recorderPda)) {
    console.log("• deployer already a recorder:", recorderPda.toBase58());
  } else {
    const sig = await oracle.methods
      .setRecorder(wallet.publicKey, true)
      .accounts({ authority: wallet.publicKey })
      .rpc();
    console.log("✓ oracle.set_recorder(deployer):", recorderPda.toBase58(), "| tx", sig);
  }

  // --- prediction_market.initialize(treasury = deployer, fee = 100bps) ---
  const [marketConfig] = PublicKey.findProgramAddressSync([Buffer.from("config")], market.programId);
  if (await accountExists(conn, marketConfig)) {
    console.log("• market config already initialized:", marketConfig.toBase58());
  } else {
    const sig = await market.methods
      .initialize(wallet.publicKey, 100)
      .accounts({ authority: wallet.publicKey })
      .rpc();
    console.log("✓ market.initialize (treasury=deployer, 1% fee):", marketConfig.toBase58(), "| tx", sig);
  }

  console.log("\nBootstrap complete. Both programs are live on devnet.");
  console.log("Frontend env (devnet):");
  console.log("  NEXT_PUBLIC_SVM_CLUSTER=devnet");
  console.log("  NEXT_PUBLIC_SVM_REALIZED_ORACLE=" + oracle.programId.toBase58());
  console.log("  NEXT_PUBLIC_SVM_PREDICTION_MARKET=" + market.programId.toBase58());
}

main().catch((e) => {
  console.error("bootstrap failed:", e.message || e);
  process.exit(1);
});
