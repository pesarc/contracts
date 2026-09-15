// LiteSVM tests for the prediction market.
//
//  1. attested_lifecycle_pays_winner — the full SPL parimutuel money path:
//     create -> stake YES/NO -> attestor proposes -> finalize -> winner claims,
//     asserting the pro-rata payout and the protocol fee.
//  2. oracle_cpi_resolves_market — loads BOTH programs and proves the closed
//     loop: the market resolves by CPI into the RealizedRateOracle's consult,
//     so the YES side wins iff the realized rate clears the threshold.
//
// The compiled BPF programs come from `anchor build`; when either is absent the
// tests skip instead of failing.

use litesvm::LiteSVM;
use solana_account::Account;
use solana_clock::Clock;
use solana_instruction::{AccountMeta, Instruction};
use solana_keypair::Keypair;
use solana_message::Message;
use solana_pubkey::{pubkey, Pubkey};
use solana_signer::Signer;
use solana_transaction::Transaction;
use std::path::PathBuf;

const PRED_ID: Pubkey = pubkey!("2aMC2CKjqwxmLrS6dv98c6pVYEKogRXxEuz3NZpzv8CZ");
const ORACLE_ID: Pubkey = pubkey!("4NUdEu7crxzR1AtHhaiMLk4q1ctTvhZLREq7Pbt9KNkK");
const SPL_TOKEN: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const SYSTEM: Pubkey = pubkey!("11111111111111111111111111111111");
const RENT: Pubkey = pubkey!("SysvarRent111111111111111111111111111111111");

// prediction-market discriminators
const D_INITIALIZE: [u8; 8] = [175, 175, 109, 31, 13, 152, 155, 237];
const D_CREATE_MARKET: [u8; 8] = [103, 226, 97, 235, 200, 188, 251, 254];
const D_STAKE: [u8; 8] = [206, 176, 202, 18, 200, 209, 179, 108];
const D_PROPOSE: [u8; 8] = [93, 253, 82, 168, 118, 33, 102, 90];
const D_PROPOSE_ORACLE: [u8; 8] = [244, 4, 149, 46, 51, 227, 30, 189];
const D_FINALIZE: [u8; 8] = [171, 61, 218, 56, 127, 115, 12, 217];
const D_CLAIM: [u8; 8] = [62, 198, 214, 193, 213, 159, 108, 210];
// oracle discriminators
const D_O_INITIALIZE: [u8; 8] = [175, 175, 109, 31, 13, 152, 155, 237];
const D_O_SET_RECORDER: [u8; 8] = [213, 241, 95, 130, 50, 251, 54, 146];
const D_O_RECORD: [u8; 8] = [222, 57, 201, 216, 199, 90, 247, 136];

const KIND_ORACLE: u8 = 0;
const KIND_ATTESTED: u8 = 1;
const CMP_GTE: u8 = 0;
const OUT_YES: u8 = 1;

fn pred_so() -> Option<PathBuf> {
    let p =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/deploy/prediction_market.so");
    p.exists().then_some(p)
}

fn oracle_so() -> Option<PathBuf> {
    // Same Anchor workspace now — both programs build into ./target/deploy, so the
    // prediction-market <-> oracle CPI test is fully local (no cross-repo path).
    let p = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/deploy/realized_rate_oracle.so");
    p.exists().then_some(p)
}

fn pda(program: &Pubkey, seeds: &[&[u8]]) -> Pubkey {
    Pubkey::find_program_address(seeds, program).0
}

fn set_time(svm: &mut LiteSVM, ts: i64) {
    let mut clock: Clock = svm.get_sysvar();
    clock.unix_timestamp = ts;
    svm.set_sysvar(&clock);
}

fn ix(program: Pubkey, accounts: Vec<AccountMeta>, data: Vec<u8>) -> Instruction {
    Instruction {
        program_id: program,
        accounts,
        data,
    }
}

fn send(svm: &mut LiteSVM, payer: &Keypair, ix: Instruction) -> Result<(), String> {
    let msg = Message::new(&[ix], Some(&payer.pubkey()));
    let tx = Transaction::new(&[payer], msg, svm.latest_blockhash());
    svm.send_transaction(tx)
        .map(|_| ())
        .map_err(|e| format!("{:?}", e.err))
}

/// Minimal SPL mint account (82-byte layout): no mint authority, decimals 0,
/// initialized.
fn mint_data() -> Vec<u8> {
    let mut d = vec![0u8; 82];
    d[45] = 1; // is_initialized (supply=0 @36..44, decimals=0 @44)
    d
}

/// SPL token account (165-byte layout) holding `amount`.
fn token_data(mint: &Pubkey, owner: &Pubkey, amount: u64) -> Vec<u8> {
    let mut d = vec![0u8; 165];
    d[0..32].copy_from_slice(mint.as_ref());
    d[32..64].copy_from_slice(owner.as_ref());
    d[64..72].copy_from_slice(&amount.to_le_bytes());
    d[108] = 1; // state = Initialized
    d
}

fn put_account(svm: &mut LiteSVM, key: Pubkey, owner: Pubkey, data: Vec<u8>) {
    svm.set_account(
        key,
        Account {
            lamports: 10_000_000,
            data,
            owner,
            executable: false,
            rent_epoch: 0,
        },
    )
    .unwrap();
}

fn balance(svm: &LiteSVM, ata: &Pubkey) -> u64 {
    let acc = svm.get_account(ata).unwrap();
    let mut b = [0u8; 8];
    b.copy_from_slice(&acc.data[64..72]);
    u64::from_le_bytes(b)
}

fn market_pda(count: u64) -> Pubkey {
    pda(&PRED_ID, &[b"market", &count.to_le_bytes()])
}

#[allow(clippy::too_many_arguments)]
fn create_market_ix(
    market: Pubkey,
    vault: Pubkey,
    mint: Pubkey,
    authority: Pubkey,
    close_time: i64,
    resolve_time: i64,
    dispute_window: i64,
    attestor: Pubkey,
    bond: u64,
    source_kind: u8,
    threshold: u128,
    token_in: Pubkey,
    token_out: Pubkey,
    twap_window: u32,
) -> Instruction {
    let mut data = D_CREATE_MARKET.to_vec();
    let q = b"test market";
    data.extend_from_slice(&(q.len() as u32).to_le_bytes());
    data.extend_from_slice(q);
    data.extend_from_slice(&close_time.to_le_bytes());
    data.extend_from_slice(&resolve_time.to_le_bytes());
    data.extend_from_slice(&dispute_window.to_le_bytes());
    data.extend_from_slice(attestor.as_ref());
    data.extend_from_slice(&bond.to_le_bytes());
    data.push(source_kind);
    data.push(CMP_GTE);
    data.extend_from_slice(&threshold.to_le_bytes());
    data.extend_from_slice(token_in.as_ref());
    data.extend_from_slice(token_out.as_ref());
    data.extend_from_slice(&twap_window.to_le_bytes());
    data.extend_from_slice(&[0u8; 32]); // feed_ref
    let config = pda(&PRED_ID, &[b"config"]);
    ix(
        PRED_ID,
        vec![
            AccountMeta::new(config, false),
            AccountMeta::new(market, false),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new(vault, false),
            AccountMeta::new(authority, true),
            AccountMeta::new_readonly(SPL_TOKEN, false),
            AccountMeta::new_readonly(SYSTEM, false),
            AccountMeta::new_readonly(RENT, false),
        ],
        data,
    )
}

fn stake_ix(
    market: Pubkey,
    vault: Pubkey,
    user: &Keypair,
    is_yes: bool,
    amount: u64,
) -> Instruction {
    let position = pda(
        &PRED_ID,
        &[b"position", market.as_ref(), user.pubkey().as_ref()],
    );
    let user_token = user_ata(&user.pubkey());
    let mut data = D_STAKE.to_vec();
    data.push(is_yes as u8);
    data.extend_from_slice(&amount.to_le_bytes());
    ix(
        PRED_ID,
        vec![
            AccountMeta::new(market, false),
            AccountMeta::new(position, false),
            AccountMeta::new(vault, false),
            AccountMeta::new(user_token, false),
            AccountMeta::new(user.pubkey(), true),
            AccountMeta::new_readonly(SPL_TOKEN, false),
            AccountMeta::new_readonly(SYSTEM, false),
        ],
        data,
    )
}

fn init_config(
    svm: &mut LiteSVM,
    authority: &Keypair,
    program: Pubkey,
    disc: [u8; 8],
    fee_bps: u16,
) {
    let config = pda(&program, &[b"config"]);
    // prediction-market initialize takes (treasury: Pubkey, fee_bps: u16);
    // oracle initialize takes no args (fee_bps ignored there).
    let mut data = disc.to_vec();
    if program == PRED_ID {
        data.extend_from_slice(authority.pubkey().as_ref()); // treasury
        data.extend_from_slice(&fee_bps.to_le_bytes());
    }
    let accounts = vec![
        AccountMeta::new(config, false),
        AccountMeta::new(authority.pubkey(), true),
        AccountMeta::new_readonly(SYSTEM, false),
    ];
    send(svm, authority, ix(program, accounts, data)).expect("initialize");
}

// Deterministic per-user ATA stand-ins (not real ATAs; the program only checks
// mint + authority, not the ATA derivation).
fn user_ata(user: &Pubkey) -> Pubkey {
    pda(&PRED_ID, &[b"testata", user.as_ref()])
}

fn fund(svm: &mut LiteSVM, mint: Pubkey, owner: &Pubkey, amount: u64) {
    put_account(
        svm,
        user_ata(owner),
        SPL_TOKEN,
        token_data(&mint, owner, amount),
    );
}

#[test]
fn attested_lifecycle_pays_winner() {
    let Some(so) = pred_so() else {
        eprintln!("skipping: prediction_market.so not built");
        return;
    };
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(PRED_ID, so).unwrap();

    let authority = Keypair::new(); // owner + attestor + treasury
    let alice = Keypair::new();
    let bob = Keypair::new();
    for k in [&authority, &alice, &bob] {
        svm.airdrop(&k.pubkey(), 10_000_000_000).unwrap();
    }
    let t = 1_700_000_000i64;
    set_time(&mut svm, t);

    let treasury = Keypair::new();
    let mint = Keypair::new().pubkey();
    put_account(&mut svm, mint, SPL_TOKEN, mint_data());
    fund(&mut svm, mint, &alice.pubkey(), 1_000_000);
    fund(&mut svm, mint, &bob.pubkey(), 1_000_000);
    fund(&mut svm, mint, &authority.pubkey(), 1_000_000); // attestor bond
    fund(&mut svm, mint, &treasury.pubkey(), 0); // fee sink

    init_config(&mut svm, &authority, PRED_ID, D_INITIALIZE, 200); // 2% fee

    let market = market_pda(0);
    let vault = pda(&PRED_ID, &[b"vault", market.as_ref()]);
    send(
        &mut svm,
        &authority,
        create_market_ix(
            market,
            vault,
            mint,
            authority.pubkey(),
            t + 50,
            t + 50,
            10,
            authority.pubkey(),
            100,
            KIND_ATTESTED,
            0,
            Pubkey::default(),
            Pubkey::default(),
            0,
        ),
    )
    .expect("create_market");

    send(&mut svm, &alice, stake_ix(market, vault, &alice, true, 300)).expect("alice stake YES");
    send(&mut svm, &bob, stake_ix(market, vault, &bob, false, 100)).expect("bob stake NO");

    // Attestor proposes YES after resolve_time (posts the bond).
    set_time(&mut svm, t + 60);
    let attestor_token = user_ata(&authority.pubkey());
    let mut pdata = D_PROPOSE.to_vec();
    pdata.push(OUT_YES);
    send(
        &mut svm,
        &authority,
        ix(
            PRED_ID,
            vec![
                AccountMeta::new(market, false),
                AccountMeta::new(vault, false),
                AccountMeta::new(attestor_token, false),
                AccountMeta::new(authority.pubkey(), true),
                AccountMeta::new_readonly(SPL_TOKEN, false),
            ],
            pdata,
        ),
    )
    .expect("propose");

    // Finalize after the dispute window. treasury_token and proposer_token must
    // be distinct accounts (Anchor forbids a duplicate mutable account).
    set_time(&mut svm, t + 80);
    let treasury_token = user_ata(&treasury.pubkey());
    send(
        &mut svm,
        &authority,
        ix(
            PRED_ID,
            vec![
                AccountMeta::new(market, false),
                AccountMeta::new(vault, false),
                AccountMeta::new(treasury_token, false), // treasury_token
                AccountMeta::new(attestor_token, false), // proposer_token (bond back)
                AccountMeta::new_readonly(SPL_TOKEN, false),
            ],
            D_FINALIZE.to_vec(),
        ),
    )
    .expect("finalize");
    assert_eq!(
        balance(&svm, &treasury_token),
        2,
        "2% fee on the 100 losing pool"
    );

    // Alice (only YES staker) claims the whole pot net of fee.
    let alice_before = balance(&svm, &user_ata(&alice.pubkey()));
    let position = pda(
        &PRED_ID,
        &[b"position", market.as_ref(), alice.pubkey().as_ref()],
    );
    send(
        &mut svm,
        &alice,
        ix(
            PRED_ID,
            vec![
                AccountMeta::new_readonly(market, false),
                AccountMeta::new(position, false),
                AccountMeta::new(vault, false),
                AccountMeta::new(user_ata(&alice.pubkey()), false),
                AccountMeta::new(alice.pubkey(), true),
                AccountMeta::new_readonly(SPL_TOKEN, false),
            ],
            D_CLAIM.to_vec(),
        ),
    )
    .expect("claim");

    // Pot = 300 YES + 100 NO; fee = 2% of the 100 losing pool = 2; payout = 398.
    let alice_after = balance(&svm, &user_ata(&alice.pubkey()));
    assert_eq!(alice_after - alice_before, 398, "alice payout");
}

#[test]
fn oracle_cpi_resolves_market() {
    let (Some(pred), Some(oracle)) = (pred_so(), oracle_so()) else {
        eprintln!("skipping: both program .so files must be built (anchor build in each repo)");
        return;
    };
    let mut svm = LiteSVM::new();
    svm.add_program_from_file(PRED_ID, pred).unwrap();
    svm.add_program_from_file(ORACLE_ID, oracle).unwrap();

    let authority = Keypair::new();
    let alice = Keypair::new();
    let bob = Keypair::new();
    for k in [&authority, &alice, &bob] {
        svm.airdrop(&k.pubkey(), 10_000_000_000).unwrap();
    }
    let t = 1_700_000_000i64;
    set_time(&mut svm, t);

    // --- Oracle: init, allow the authority as a recorder, record a rate. ---
    init_config(&mut svm, &authority, ORACLE_ID, D_O_INITIALIZE, 0);
    let token_in = pubkey!("So11111111111111111111111111111111111111112");
    let token_out = Keypair::new().pubkey();
    let o_config = pda(&ORACLE_ID, &[b"config"]);
    let o_rec = pda(&ORACLE_ID, &[b"recorder", authority.pubkey().as_ref()]);
    let mut sr = D_O_SET_RECORDER.to_vec();
    sr.extend_from_slice(authority.pubkey().as_ref());
    sr.push(1);
    send(
        &mut svm,
        &authority,
        ix(
            ORACLE_ID,
            vec![
                AccountMeta::new_readonly(o_config, false),
                AccountMeta::new(o_rec, false),
                AccountMeta::new(authority.pubkey(), true),
                AccountMeta::new_readonly(SYSTEM, false),
            ],
            sr,
        ),
    )
    .expect("set_recorder");

    let o_pair = pda(
        &ORACLE_ID,
        &[b"pair", token_in.as_ref(), token_out.as_ref()],
    );
    let mut rd = D_O_RECORD.to_vec();
    rd.extend_from_slice(token_in.as_ref());
    rd.extend_from_slice(token_out.as_ref());
    rd.extend_from_slice(&2_000_000u128.to_le_bytes()); // realized rate
    send(
        &mut svm,
        &authority,
        ix(
            ORACLE_ID,
            vec![
                AccountMeta::new(o_pair, false),
                AccountMeta::new_readonly(o_rec, false),
                AccountMeta::new(authority.pubkey(), true),
                AccountMeta::new_readonly(SYSTEM, false),
            ],
            rd,
        ),
    )
    .expect("record");

    // --- Market: oracle-kind, threshold 1.6e6 (rate 2e6 >= threshold -> YES). ---
    let mint = token_out;
    put_account(&mut svm, mint, SPL_TOKEN, mint_data());
    fund(&mut svm, mint, &alice.pubkey(), 1_000_000);
    fund(&mut svm, mint, &bob.pubkey(), 1_000_000);
    init_config(&mut svm, &authority, PRED_ID, D_INITIALIZE, 0);

    let market = market_pda(0);
    let vault = pda(&PRED_ID, &[b"vault", market.as_ref()]);
    send(
        &mut svm,
        &authority,
        create_market_ix(
            market,
            vault,
            mint,
            authority.pubkey(),
            t + 50,
            t + 50,
            0,
            Pubkey::default(),
            0,
            KIND_ORACLE,
            1_600_000,
            token_in,
            token_out,
            3600,
        ),
    )
    .expect("create_market");
    send(&mut svm, &alice, stake_ix(market, vault, &alice, true, 100)).expect("alice YES");
    send(&mut svm, &bob, stake_ix(market, vault, &bob, false, 100)).expect("bob NO");

    // Resolve by CPI into the oracle (permissionless), then finalize.
    set_time(&mut svm, t + 60);
    send(
        &mut svm,
        &authority,
        ix(
            PRED_ID,
            vec![
                AccountMeta::new(market, false),
                AccountMeta::new_readonly(ORACLE_ID, false),
                AccountMeta::new_readonly(o_pair, false),
            ],
            D_PROPOSE_ORACLE.to_vec(),
        ),
    )
    .expect("propose_from_oracle (CPI)");

    // Distinct token accounts for the two mutable fields (fee=0 and proposer is
    // default here, so nothing actually moves — but they must differ + be valid).
    fund(&mut svm, mint, &authority.pubkey(), 0);
    let treasury_token = user_ata(&authority.pubkey());
    let proposer_token = user_ata(&bob.pubkey());
    send(
        &mut svm,
        &authority,
        ix(
            PRED_ID,
            vec![
                AccountMeta::new(market, false),
                AccountMeta::new(vault, false),
                AccountMeta::new(treasury_token, false),
                AccountMeta::new(proposer_token, false),
                AccountMeta::new_readonly(SPL_TOKEN, false),
            ],
            D_FINALIZE.to_vec(),
        ),
    )
    .expect("finalize");

    // YES won (2e6 >= 1.6e6): alice claims, bob cannot.
    let alice_before = balance(&svm, &user_ata(&alice.pubkey()));
    let a_pos = pda(
        &PRED_ID,
        &[b"position", market.as_ref(), alice.pubkey().as_ref()],
    );
    send(
        &mut svm,
        &alice,
        ix(
            PRED_ID,
            vec![
                AccountMeta::new_readonly(market, false),
                AccountMeta::new(a_pos, false),
                AccountMeta::new(vault, false),
                AccountMeta::new(user_ata(&alice.pubkey()), false),
                AccountMeta::new(alice.pubkey(), true),
                AccountMeta::new_readonly(SPL_TOKEN, false),
            ],
            D_CLAIM.to_vec(),
        ),
    )
    .expect("alice claim (YES won via oracle)");
    assert_eq!(
        balance(&svm, &user_ata(&alice.pubkey())) - alice_before,
        200,
        "alice takes the pot"
    );

    let b_pos = pda(
        &PRED_ID,
        &[b"position", market.as_ref(), bob.pubkey().as_ref()],
    );
    let bob_claim = send(
        &mut svm,
        &bob,
        ix(
            PRED_ID,
            vec![
                AccountMeta::new_readonly(market, false),
                AccountMeta::new(b_pos, false),
                AccountMeta::new(vault, false),
                AccountMeta::new(user_ata(&bob.pubkey()), false),
                AccountMeta::new(bob.pubkey(), true),
                AccountMeta::new_readonly(SPL_TOKEN, false),
            ],
            D_CLAIM.to_vec(),
        ),
    );
    assert!(
        bob_claim.is_err(),
        "NO side cannot claim after YES resolution"
    );
}
