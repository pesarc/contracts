// LiteSVM tests for the RealizedRateOracle: recorder gating, realized-print
// accrual, and the trailing-window TWAP + spot read (returned via return data).
//
// The compiled BPF program comes from `anchor build` (cargo build-sbf), not
// `cargo test`; when it is absent these tests skip instead of failing.

use litesvm::LiteSVM;
use solana_clock::Clock;
use solana_instruction::{AccountMeta, Instruction};
use solana_keypair::Keypair;
use solana_message::Message;
use solana_pubkey::{pubkey, Pubkey};
use solana_signer::Signer;
use solana_transaction::Transaction;
use std::path::PathBuf;

const PROGRAM_ID: Pubkey = pubkey!("4NUdEu7crxzR1AtHhaiMLk4q1ctTvhZLREq7Pbt9KNkK");
const SYSTEM: Pubkey = pubkey!("11111111111111111111111111111111");

// Anchor discriminators = sha256("global:<ix>")[..8].
const D_INITIALIZE: [u8; 8] = [175, 175, 109, 31, 13, 152, 155, 237];
const D_SET_RECORDER: [u8; 8] = [213, 241, 95, 130, 50, 251, 54, 146];
const D_RECORD: [u8; 8] = [222, 57, 201, 216, 199, 90, 247, 136];
const D_CONSULT: [u8; 8] = [65, 242, 246, 89, 73, 197, 128, 71];
const D_LATEST: [u8; 8] = [13, 12, 144, 15, 90, 209, 43, 94];

fn program_so() -> Option<PathBuf> {
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/deploy/realized_rate_oracle.so");
    p.exists().then_some(p)
}

fn pda(seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, &PROGRAM_ID).0
}

fn set_time(svm: &mut LiteSVM, ts: i64) {
    let mut clock: Clock = svm.get_sysvar();
    clock.unix_timestamp = ts;
    svm.set_sysvar(&clock);
}

/// Send a single-instruction tx signed by `payer`; returns Ok(return_data).
fn send(svm: &mut LiteSVM, payer: &Keypair, ix: Instruction) -> Result<Vec<u8>, String> {
    let msg = Message::new(&[ix], Some(&payer.pubkey()));
    let tx = Transaction::new(&[payer], msg, svm.latest_blockhash());
    match svm.send_transaction(tx) {
        Ok(meta) => Ok(meta.return_data.data),
        Err(e) => Err(format!("{:?}", e.err)),
    }
}

fn ix(accounts: Vec<AccountMeta>, data: Vec<u8>) -> Instruction {
    Instruction {
        program_id: PROGRAM_ID,
        accounts,
        data,
    }
}

fn setup() -> Option<(LiteSVM, Keypair)> {
    let so = program_so()?;
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(PROGRAM_ID, so).unwrap();
    let authority = Keypair::new();
    svm.airdrop(&authority.pubkey(), 10_000_000_000).unwrap();
    set_time(&mut svm, 1_000_000_000);
    Some((svm, authority))
}

fn initialize(svm: &mut LiteSVM, authority: &Keypair) {
    let config = pda(&[b"config"]);
    let accounts = vec![
        AccountMeta::new(config, false),
        AccountMeta::new(authority.pubkey(), true),
        AccountMeta::new_readonly(SYSTEM, false),
    ];
    send(svm, authority, ix(accounts, D_INITIALIZE.to_vec())).expect("initialize");
}

fn allow_recorder(svm: &mut LiteSVM, authority: &Keypair, recorder: Pubkey) {
    let config = pda(&[b"config"]);
    let rec = pda(&[b"recorder", recorder.as_ref()]);
    let mut data = D_SET_RECORDER.to_vec();
    data.extend_from_slice(recorder.as_ref());
    data.push(1); // allowed = true
    let accounts = vec![
        AccountMeta::new_readonly(config, false),
        AccountMeta::new(rec, false),
        AccountMeta::new(authority.pubkey(), true),
        AccountMeta::new_readonly(SYSTEM, false),
    ];
    send(svm, authority, ix(accounts, data)).expect("set_recorder");
}

fn record(
    svm: &mut LiteSVM,
    signer: &Keypair,
    token_in: Pubkey,
    token_out: Pubkey,
    rate_1e18: u128,
) -> Result<Vec<u8>, String> {
    let pair = pda(&[b"pair", token_in.as_ref(), token_out.as_ref()]);
    let rec = pda(&[b"recorder", signer.pubkey().as_ref()]);
    let mut data = D_RECORD.to_vec();
    data.extend_from_slice(token_in.as_ref());
    data.extend_from_slice(token_out.as_ref());
    data.extend_from_slice(&rate_1e18.to_le_bytes());
    let accounts = vec![
        AccountMeta::new(pair, false),
        AccountMeta::new_readonly(rec, false),
        AccountMeta::new(signer.pubkey(), true),
        AccountMeta::new_readonly(SYSTEM, false),
    ];
    send(svm, signer, ix(accounts, data))
}

fn read_u128(svm: &mut LiteSVM, payer: &Keypair, disc: [u8; 8], window: Option<u32>) -> u128 {
    let (a, b) = demo_pair();
    let pair = pda(&[b"pair", a.as_ref(), b.as_ref()]);
    let mut data = disc.to_vec();
    data.extend_from_slice(a.as_ref());
    data.extend_from_slice(b.as_ref());
    if let Some(w) = window {
        data.extend_from_slice(&w.to_le_bytes());
    }
    let out = send(
        svm,
        payer,
        ix(vec![AccountMeta::new_readonly(pair, false)], data),
    )
    .expect("read");
    let mut buf = [0u8; 16];
    buf.copy_from_slice(&out[..16]);
    u128::from_le_bytes(buf)
}

fn demo_pair() -> (Pubkey, Pubkey) {
    (
        pubkey!("So11111111111111111111111111111111111111112"),
        PROGRAM_ID,
    )
}

#[test]
fn twap_and_spot_from_realized_prints() {
    let Some((mut svm, authority)) = setup() else {
        eprintln!("skipping: realized_rate_oracle.so not built (run `anchor build`)");
        return;
    };
    initialize(&mut svm, &authority);
    allow_recorder(&mut svm, &authority, authority.pubkey());

    let (a, b) = demo_pair();

    // t0: seed at 1_000_000; t0+100: print 3_000_000.
    set_time(&mut svm, 1_000_000_000);
    record(&mut svm, &authority, a, b, 1_000_000).expect("record #1");
    set_time(&mut svm, 1_000_000_100);
    record(&mut svm, &authority, a, b, 3_000_000).expect("record #2");

    // t0+200: consult over a window reaching past the oldest observation.
    set_time(&mut svm, 1_000_000_200);
    let twap = read_u128(&mut svm, &authority, D_CONSULT, Some(100_000));
    // cumulative = 1e6*100 (accrued) + 3e6*100 (running) = 4e8 over 200s = 2e6.
    assert_eq!(twap, 2_000_000, "TWAP over the full history");

    let spot = read_u128(&mut svm, &authority, D_LATEST, None);
    assert_eq!(spot, 3_000_000, "latest spot rate");
}

#[test]
fn non_recorder_cannot_record() {
    let Some((mut svm, authority)) = setup() else {
        return;
    };
    initialize(&mut svm, &authority);

    // A signer with no (allowed) recorder PDA must be rejected.
    let outsider = Keypair::new();
    svm.airdrop(&outsider.pubkey(), 10_000_000_000).unwrap();
    let (a, b) = demo_pair();
    let err = record(&mut svm, &outsider, a, b, 1_000_000)
        .expect_err("outsider must not be able to record");
    assert!(!err.is_empty());
}
