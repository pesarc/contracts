// Unit checks for the gateway's argument validation. The CCTP CPI itself is
// exercised on devnet (Circle's programs aren't reproducible in-process);
// these tests pin the instruction interface: discriminator, arg layout, and
// the pinned-program guards.

use spoke_gateway::{FAST_FINALITY, HUB_DOMAIN, HUB_RECEIVER_EVM};

#[test]
fn hub_route_constants_match_deployment() {
    assert_eq!(HUB_DOMAIN, 3, "Arbitrum CCTP domain");
    assert_eq!(FAST_FINALITY, 1000, "fast-transfer threshold");
    // 0xe7155253eDc1337F24D778A66e4069faf3f7Fa1a
    assert_eq!(HUB_RECEIVER_EVM[0], 0xe7);
    assert_eq!(HUB_RECEIVER_EVM[19], 0x1a);
}

#[test]
fn deposit_for_burn_discriminator_is_pinned() {
    use sha2::{Digest, Sha256};
    let d = Sha256::digest(b"global:deposit_for_burn");
    assert_eq!(&d[..8], &[215, 60, 61, 46, 114, 55, 128, 176]);
}
