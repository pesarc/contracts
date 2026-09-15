//! StableArc Spoke Gateway — Solana (Wave 3, Engineering Spec v0.3 §3.3)
//!
//! The Solana entry point of the hub-and-spoke model: a user deposits native
//! (Circle) USDC on Solana, the gateway burns it over CCTP V2 toward the
//! Arbitrum hub's HubBridgeReceiver, and emits the transfer intent the
//! relayer pairs with Circle's attestation to deliver on the hub — credited
//! as hub USD or auto-converted to the local stable (cNGN).
//!
//! Design: a thin, non-custodial pass-through. The program never holds
//! funds; Circle's TokenMessengerMinterV2 enforces every account constraint
//! (ownership, denylist, local token, domain). The gateway pins the CCTP
//! program IDs and the hub route as immutable constants — same trust shape
//! as the EVM SpokeGateway.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::instruction::{AccountMeta, Instruction};
use anchor_lang::solana_program::program::invoke;

declare_id!("Gi1uEn2LbSm8xM9LXpyZ5ZSbiqhLsqQ7ntgM33pbT2Ki");

/// Circle CCTP V2 on Solana devnet (same IDs on mainnet-beta).
pub const TOKEN_MESSENGER_MINTER_V2: Pubkey =
    pubkey!("CCTPV2vPZJS2u2BBsUoscuikbYjnpFmbFsvVuJdgUMQe");
pub const MESSAGE_TRANSMITTER_V2: Pubkey = pubkey!("CCTPV2Sm4AdWt5296sk4P66VBZ7bEhcARwFaaS9YPbeC");
pub const SPL_TOKEN_PROGRAM: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
/// Circle USDC mint on Solana devnet — the only mint this corridor burns.
pub const USDC_MINT: Pubkey = pubkey!("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");

/// CCTP domain of the StableArc hub (Arbitrum).
pub const HUB_DOMAIN: u32 = 3;
/// HubBridgeReceiver on Arbitrum Sepolia (0xe7155253eDc1337F24D778A66e4069faf3f7Fa1a).
pub const HUB_RECEIVER_EVM: [u8; 20] = [
    0xe7, 0x15, 0x52, 0x53, 0xed, 0xc1, 0x33, 0x7f, 0x24, 0xd7, 0x78, 0xa6, 0x6e, 0x40, 0x69, 0xfa,
    0xf3, 0xf7, 0xfa, 0x1a,
];
/// CCTP V2 fast-transfer finality threshold (soft finality).
pub const FAST_FINALITY: u32 = 1000;

/// Anchor discriminator of TokenMessengerMinterV2's `deposit_for_burn`.
const DEPOSIT_FOR_BURN_DISC: [u8; 8] = [215, 60, 61, 46, 114, 55, 128, 176];

#[program]
pub mod spoke_gateway {
    use super::*;

    /// Burns `amount` of the caller's USDC toward the hub over CCTP V2.
    ///
    /// * `hub_recipient` — EVM address credited on the hub.
    /// * `convert_to_local` — true = auto-convert to cNGN on arrival.
    /// * `max_fee` — max CCTP fast-transfer fee accepted (USDC units).
    /// * `reference` — off-chain reference carried in the intent event.
    pub fn send_to_hub(
        ctx: Context<SendToHub>,
        amount: u64,
        max_fee: u64,
        hub_recipient: [u8; 20],
        convert_to_local: bool,
        reference: [u8; 32],
    ) -> Result<()> {
        require!(amount > 0, GatewayError::BadAmount);
        require!(hub_recipient != [0u8; 20], GatewayError::BadRecipient);

        // Mint recipient on the hub is ALWAYS the bridge receiver — funds
        // can only land in the reserve-backed credit path, never a raw EOA.
        let mut mint_recipient = [0u8; 32];
        mint_recipient[12..].copy_from_slice(&HUB_RECEIVER_EVM);

        // DepositForBurnParams (borsh): amount, destination_domain,
        // mint_recipient, destination_caller, max_fee, min_finality_threshold
        let mut data = Vec::with_capacity(8 + 8 + 4 + 32 + 32 + 8 + 4);
        data.extend_from_slice(&DEPOSIT_FOR_BURN_DISC);
        data.extend_from_slice(&amount.to_le_bytes());
        data.extend_from_slice(&HUB_DOMAIN.to_le_bytes());
        data.extend_from_slice(&mint_recipient);
        data.extend_from_slice(&[0u8; 32]); // destination_caller: anyone may finalize
        data.extend_from_slice(&max_fee.to_le_bytes());
        data.extend_from_slice(&FAST_FINALITY.to_le_bytes());

        let a = &ctx.accounts;
        let ix = Instruction {
            program_id: TOKEN_MESSENGER_MINTER_V2,
            accounts: vec![
                AccountMeta::new_readonly(a.owner.key(), true),
                AccountMeta::new(a.event_rent_payer.key(), true),
                AccountMeta::new_readonly(a.sender_authority_pda.key(), false),
                AccountMeta::new(a.burn_token_account.key(), false),
                AccountMeta::new_readonly(a.denylist_account.key(), false),
                AccountMeta::new(a.message_transmitter.key(), false),
                AccountMeta::new_readonly(a.token_messenger.key(), false),
                AccountMeta::new_readonly(a.remote_token_messenger.key(), false),
                AccountMeta::new_readonly(a.token_minter.key(), false),
                AccountMeta::new(a.local_token.key(), false),
                AccountMeta::new(a.burn_token_mint.key(), false),
                AccountMeta::new(a.message_sent_event_data.key(), true),
                AccountMeta::new_readonly(MESSAGE_TRANSMITTER_V2, false),
                AccountMeta::new_readonly(TOKEN_MESSENGER_MINTER_V2, false),
                AccountMeta::new_readonly(SPL_TOKEN_PROGRAM, false),
                AccountMeta::new_readonly(a.system_program.key(), false),
                // #[event_cpi] trailing accounts on the CCTP side:
                AccountMeta::new_readonly(a.cctp_event_authority.key(), false),
                AccountMeta::new_readonly(TOKEN_MESSENGER_MINTER_V2, false),
            ],
            data,
        };

        invoke(
            &ix,
            &[
                a.owner.to_account_info(),
                a.event_rent_payer.to_account_info(),
                a.sender_authority_pda.to_account_info(),
                a.burn_token_account.to_account_info(),
                a.denylist_account.to_account_info(),
                a.message_transmitter.to_account_info(),
                a.token_messenger.to_account_info(),
                a.remote_token_messenger.to_account_info(),
                a.token_minter.to_account_info(),
                a.local_token.to_account_info(),
                a.burn_token_mint.to_account_info(),
                a.message_sent_event_data.to_account_info(),
                a.message_transmitter_program.to_account_info(),
                a.token_messenger_minter_program.to_account_info(),
                a.token_program.to_account_info(),
                a.system_program.to_account_info(),
                a.cctp_event_authority.to_account_info(),
            ],
        )?;

        emit!(IntentCreated {
            sender: a.owner.key(),
            hub_recipient,
            amount,
            convert_to_local,
            reference,
        });
        Ok(())
    }
}

#[derive(Accounts)]
pub struct SendToHub<'info> {
    /// Owner of the USDC token account being burned.
    pub owner: Signer<'info>,

    /// Pays rent for CCTP's per-message event account.
    #[account(mut)]
    pub event_rent_payer: Signer<'info>,

    /// CHECK: CCTP PDA ["sender_authority"] — validated by CCTP.
    pub sender_authority_pda: UncheckedAccount<'info>,

    /// CHECK: user's USDC token account — CCTP enforces mint + ownership.
    #[account(mut)]
    pub burn_token_account: UncheckedAccount<'info>,

    /// CHECK: CCTP PDA ["denylist_account", owner] — validated by CCTP.
    pub denylist_account: UncheckedAccount<'info>,

    /// CHECK: MessageTransmitterV2 state — validated by CCTP.
    #[account(mut)]
    pub message_transmitter: UncheckedAccount<'info>,

    /// CHECK: TokenMessenger state — validated by CCTP.
    pub token_messenger: UncheckedAccount<'info>,

    /// CHECK: RemoteTokenMessenger for the hub domain — validated by CCTP.
    pub remote_token_messenger: UncheckedAccount<'info>,

    /// CHECK: TokenMinter state — validated by CCTP.
    pub token_minter: UncheckedAccount<'info>,

    /// CHECK: LocalToken PDA for USDC — validated by CCTP.
    #[account(mut)]
    pub local_token: UncheckedAccount<'info>,

    /// CHECK: pinned to the corridor's USDC mint (and re-validated by CCTP).
    #[account(mut, address = USDC_MINT @ GatewayError::BadMint)]
    pub burn_token_mint: UncheckedAccount<'info>,

    /// Fresh keypair; CCTP stores the outbound message here.
    #[account(mut)]
    pub message_sent_event_data: Signer<'info>,

    /// CHECK: pinned to MESSAGE_TRANSMITTER_V2.
    #[account(address = MESSAGE_TRANSMITTER_V2 @ GatewayError::BadCctpProgram)]
    pub message_transmitter_program: UncheckedAccount<'info>,

    /// CHECK: pinned to TOKEN_MESSENGER_MINTER_V2.
    #[account(address = TOKEN_MESSENGER_MINTER_V2 @ GatewayError::BadCctpProgram)]
    pub token_messenger_minter_program: UncheckedAccount<'info>,

    /// CHECK: pinned to the SPL token program.
    #[account(address = SPL_TOKEN_PROGRAM @ GatewayError::BadCctpProgram)]
    pub token_program: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,

    /// CHECK: CCTP's ["__event_authority"] PDA — validated by CCTP.
    pub cctp_event_authority: UncheckedAccount<'info>,
}

#[event]
pub struct IntentCreated {
    pub sender: Pubkey,
    pub hub_recipient: [u8; 20],
    pub amount: u64,
    pub convert_to_local: bool,
    pub reference: [u8; 32],
}

#[error_code]
pub enum GatewayError {
    #[msg("amount must be greater than zero")]
    BadAmount,
    #[msg("hub recipient must not be the zero address")]
    BadRecipient,
    #[msg("account does not match the pinned CCTP program")]
    BadCctpProgram,
    #[msg("burn mint must be the corridor USDC mint")]
    BadMint,
}
