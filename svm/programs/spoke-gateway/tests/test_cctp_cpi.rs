// Integration test: runs Circle's REAL CCTP V2 programs (dumped from devnet
// into ../fixtures) inside LiteSVM and drives our send_to_hub instruction
// end-to-end — proving the CPI account list, discriminator, and arg layout
// against the genuine TokenMessengerMinterV2, without touching the network.

use litesvm::LiteSVM;
use solana_keypair::Keypair;
use solana_message::Message;
use solana_signer::Signer;
use solana_transaction::Transaction;
use std::path::PathBuf;
use std::str::FromStr;

use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;

const SPOKE_GATEWAY: &str = "Gi1uEn2LbSm8xM9LXpyZ5ZSbiqhLsqQ7ntgM33pbT2Ki";
const TMM: &str = "CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe";
const MT: &str = "CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC";
const USDC: &str = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU";
const TOKEN_PROGRAM: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const ATA_PROGRAM: &str = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
const SYSTEM: &str = "11111111111111111111111111111111";

const SEND_TO_HUB_DISC: [u8; 8] = [201, 122, 202, 2, 75, 213, 164, 105];

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures")
}

fn pk(s: &str) -> Pubkey {
    Pubkey::from_str(s).unwrap()
}

/// Loads a `solana account --output json` fixture into the VM.
fn load_account(svm: &mut LiteSVM, address: &str) {
    let raw = std::fs::read_to_string(fixtures().join(format!("{address}.json")))
        .unwrap_or_else(|_| panic!("missing fixture {address}"));
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let acc = &v["account"];
    let data_b64 = acc["data"][0].as_str().unwrap();
    use base64::Engine;
    let data = base64::engine::general_purpose::STANDARD
        .decode(data_b64)
        .unwrap();
    svm.set_account(
        pk(address),
        Account {
            lamports: acc["lamports"].as_u64().unwrap(),
            data,
            owner: pk(acc["owner"].as_str().unwrap()),
            executable: false,
            rent_epoch: 0,
        },
    )
    .unwrap();
}

/// Hand-crafts an SPL token account (165-byte layout) holding `amount` USDC.
fn token_account_data(mint: &Pubkey, owner: &Pubkey, amount: u64) -> Vec<u8> {
    let mut d = vec![0u8; 165];
    d[0..32].copy_from_slice(mint.as_ref());
    d[32..64].copy_from_slice(owner.as_ref());
    d[64..72].copy_from_slice(&amount.to_le_bytes());
    // delegate: COption::None (4 zero bytes already)
    d[108] = 1; // state = Initialized
    d
}

struct Setup {
    svm: LiteSVM,
    user: Keypair,
    ata: Pubkey,
}

/// The compiled BPF program is produced by `anchor build` (cargo build-sbf),
/// not by `cargo test`. When it's absent (e.g. a fmt-only CI job) these
/// integration tests skip instead of failing — run `anchor build` first for
/// the full CCTP CPI coverage.
fn program_so() -> Option<PathBuf> {
    let p = fixtures().join("../target/deploy/spoke_gateway.so");
    p.exists().then_some(p)
}

fn setup(usdc_balance: u64) -> Setup {
    let mut svm = LiteSVM::new();

    svm.add_program_from_file(pk(SPOKE_GATEWAY), program_so().unwrap())
        .unwrap();
    svm.add_program_from_file(pk(TMM), fixtures().join("tmm_v2.so"))
        .unwrap();
    svm.add_program_from_file(pk(MT), fixtures().join("mt_v2.so"))
        .unwrap();

    // Real devnet state: messenger/minter/transmitter config + the USDC mint.
    for a in [
        "AawthJCGRmggpfv9MMWV6Jmo9cue4gL9wUZgRBShg58W", // token_messenger
        "53NSDvEXmUixWSsCQF5rnTxcKdihq19WXNaZFXrX3ojf", // remote_token_messenger(3)
        "E1bQJ8eMMn3zmeSewW3HQ8zmJr7KR75JonbwAtWx2bux", // token_minter
        "7MwmWTK2R9Na6rnoSAEt5gytFmSZj9WLVdazvxvru9AU", // local_token
        "W1k5ijkaSTo5iA5zChNpfzcy796fLhkBxfmJuR8W8HU",  // message_transmitter
        USDC,
    ] {
        load_account(&mut svm, a);
    }

    let user = Keypair::new();
    svm.airdrop(&user.pubkey(), 10_000_000_000).unwrap();

    // User's USDC ATA at its canonical address.
    let (ata, _) = Pubkey::find_program_address(
        &[
            user.pubkey().as_ref(),
            pk(TOKEN_PROGRAM).as_ref(),
            pk(USDC).as_ref(),
        ],
        &pk(ATA_PROGRAM),
    );
    svm.set_account(
        ata,
        Account {
            lamports: 2_039_280,
            data: token_account_data(&pk(USDC), &user.pubkey(), usdc_balance),
            owner: pk(TOKEN_PROGRAM),
            executable: false,
            rent_epoch: 0,
        },
    )
    .unwrap();

    Setup { svm, user, ata }
}

fn send_to_hub_ix(
    user: &Pubkey,
    ata: &Pubkey,
    event_data: &Pubkey,
    amount: u64,
    hub_recipient: [u8; 20],
) -> Instruction {
    let tmm = pk(TMM);
    let mt = pk(MT);
    let seedpda = |seeds: &[&[u8]], prog: &Pubkey| Pubkey::find_program_address(seeds, prog).0;

    let mut data = Vec::new();
    data.extend_from_slice(&SEND_TO_HUB_DISC);
    data.extend_from_slice(&amount.to_le_bytes());
    data.extend_from_slice(&(amount / 100).max(1).to_le_bytes()); // max_fee
    data.extend_from_slice(&hub_recipient);
    data.push(1); // convert_to_local
    data.extend_from_slice(&[7u8; 32]); // reference

    Instruction {
        program_id: pk(SPOKE_GATEWAY),
        accounts: vec![
            AccountMeta::new_readonly(*user, true),
            AccountMeta::new(*user, true), // event_rent_payer
            AccountMeta::new_readonly(seedpda(&[b"sender_authority"], &tmm), false),
            AccountMeta::new(*ata, false),
            AccountMeta::new_readonly(seedpda(&[b"denylist_account", user.as_ref()], &tmm), false),
            AccountMeta::new(seedpda(&[b"message_transmitter"], &mt), false),
            AccountMeta::new_readonly(seedpda(&[b"token_messenger"], &tmm), false),
            AccountMeta::new_readonly(seedpda(&[b"remote_token_messenger", b"3"], &tmm), false),
            AccountMeta::new_readonly(seedpda(&[b"token_minter"], &tmm), false),
            AccountMeta::new(seedpda(&[b"local_token", pk(USDC).as_ref()], &tmm), false),
            AccountMeta::new(pk(USDC), false),
            AccountMeta::new(*event_data, true),
            AccountMeta::new_readonly(mt, false),
            AccountMeta::new_readonly(tmm, false),
            AccountMeta::new_readonly(pk(TOKEN_PROGRAM), false),
            AccountMeta::new_readonly(pk(SYSTEM), false),
            AccountMeta::new_readonly(seedpda(&[b"__event_authority"], &tmm), false),
        ],
        data,
    }
}

#[test]
fn burns_usdc_through_real_cctp_v2() {
    if program_so().is_none() {
        eprintln!("skipping: run `anchor build` to produce the BPF program");
        return;
    }

    let mut s = setup(25_000_000); // 25 USDC
    let event_data = Keypair::new();
    let hub_recipient: [u8; 20] = [0xd4; 20];

    let ix = send_to_hub_ix(
        &s.user.pubkey(),
        &s.ata,
        &event_data.pubkey(),
        5_000_000, // burn 5 USDC
        hub_recipient,
    );
    let msg = Message::new(&[ix], Some(&s.user.pubkey()));
    let tx = Transaction::new(&[&s.user, &event_data], msg, s.svm.latest_blockhash());
    let meta = s
        .svm
        .send_transaction(tx)
        .unwrap_or_else(|f| panic!("tx failed: {:?}\nlogs: {:#?}", f.err, f.meta.logs));

    // USDC actually burned from the user's account by Circle's program.
    let ata_data = s.svm.get_account(&s.ata).unwrap().data;
    let balance = u64::from_le_bytes(ata_data[64..72].try_into().unwrap());
    assert_eq!(balance, 20_000_000, "5 USDC burned");

    // CCTP stored the outbound message; our intent event was emitted.
    let msg_acct = s.svm.get_account(&event_data.pubkey()).unwrap();
    assert_eq!(
        msg_acct.owner,
        pk(MT),
        "MessageSent account owned by transmitter"
    );
    assert!(msg_acct.data.len() > 100, "outbound message recorded");
    assert!(
        meta.logs.iter().any(|l| l.contains("Program data:")),
        "IntentCreated event emitted"
    );
}

#[test]
fn rejects_zero_amount_and_zero_recipient() {
    if program_so().is_none() {
        eprintln!("skipping: run `anchor build` to produce the BPF program");
        return;
    }

    let mut s = setup(1_000_000);
    let event_data = Keypair::new();

    for (amount, recipient) in [(0u64, [0xd4u8; 20]), (1_000_000u64, [0u8; 20])] {
        let ix = send_to_hub_ix(
            &s.user.pubkey(),
            &s.ata,
            &event_data.pubkey(),
            amount,
            recipient,
        );
        let msg = Message::new(&[ix], Some(&s.user.pubkey()));
        let tx = Transaction::new(&[&s.user, &event_data], msg, s.svm.latest_blockhash());
        assert!(s.svm.send_transaction(tx).is_err(), "must reject bad args");
    }
}

#[test]
fn rejects_spoofed_cctp_program() {
    if program_so().is_none() {
        eprintln!("skipping: run `anchor build` to produce the BPF program");
        return;
    }

    let mut s = setup(1_000_000);
    let event_data = Keypair::new();
    let mut ix = send_to_hub_ix(
        &s.user.pubkey(),
        &s.ata,
        &event_data.pubkey(),
        1_000_000,
        [0xd4; 20],
    );
    // Swap the pinned token-messenger program for an imposter.
    ix.accounts[13] = AccountMeta::new_readonly(pk(SYSTEM), false);
    let msg = Message::new(&[ix], Some(&s.user.pubkey()));
    let tx = Transaction::new(&[&s.user, &event_data], msg, s.svm.latest_blockhash());
    assert!(
        s.svm.send_transaction(tx).is_err(),
        "pinned-program guard must reject substitution"
    );
}
