// Helper: prints the CCTP V2 PDAs needed for devnet fixtures.
// Run: cargo test --test print_pdas -- --nocapture
use anchor_lang::prelude::Pubkey;
use spoke_gateway::{MESSAGE_TRANSMITTER_V2, TOKEN_MESSENGER_MINTER_V2};
use std::str::FromStr;

#[test]
fn print_pdas() {
    let usdc = Pubkey::from_str("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU").unwrap();
    let tmm = TOKEN_MESSENGER_MINTER_V2;
    let mt = MESSAGE_TRANSMITTER_V2;
    let pdas = [
        (
            "sender_authority",
            Pubkey::find_program_address(&[b"sender_authority"], &tmm).0,
        ),
        (
            "token_messenger",
            Pubkey::find_program_address(&[b"token_messenger"], &tmm).0,
        ),
        (
            "remote_token_messenger_3",
            Pubkey::find_program_address(&[b"remote_token_messenger", b"3"], &tmm).0,
        ),
        (
            "token_minter",
            Pubkey::find_program_address(&[b"token_minter"], &tmm).0,
        ),
        (
            "local_token",
            Pubkey::find_program_address(&[b"local_token", usdc.as_ref()], &tmm).0,
        ),
        (
            "event_authority",
            Pubkey::find_program_address(&[b"__event_authority"], &tmm).0,
        ),
        (
            "message_transmitter",
            Pubkey::find_program_address(&[b"message_transmitter"], &mt).0,
        ),
    ];
    for (n, p) in pdas {
        println!("PDA {} {}", n, p);
    }
}
