// ══════════════════════════════════════════════════════════════════════════════
// LumpFun v4 / LumpPad — the USDCx-QUOTED cohort. Every constant is denominated
// in the quote token ($USDCx, 6 decimals → BASE UNITS), never in ADA. ADA appears
// in exactly one place: the fixed min-UTxO floor the pool UTxO must carry.
//
// This cohort is the NIGHT cohort (`cardano-v4-night`) — validators byte-for-byte —
// compiled against a different quote asset and quote-unit constants. Like NIGHT it
// carries the H-1 fix from the 2026-09-12 review of the LUMP cohort:
//   • `Claim` must be SIGNED by the creator or the treasury key (no permissionless
//     claims, so nobody can grief a payout into an unspendable address);
//   • every payout must go to a VERIFICATION-KEY credential — a script credential
//     of the same hash is refused (fees_v4.pays_quote_at_least).
//
// ── THE "BURN HALF" IS A LUMP BUYBACK, NOT A USDCx BURN. ──────────────────────
// On the LUMP cohort half of the platform fee is paid to an always-fail script,
// destroying LUMP for good. Destroying USDCx would do nothing for $LUMP holders,
// so on this cohort that half is paid to a dedicated BUYBACK key
// (`buyback_pkh_v4`): the operator buys LUMP with it and burns that by hand.
// The split itself (platform_owed / 2) is still enforced on chain.
//
// ── ONE PHASE. NO GRADUATION. FEES ACCRUE INSIDE THE POOL. ────────────────────
// Unchanged from the LUMP cohort — see its own `params_v4.ak`.
//
// ── SCALE IS RELATIVE TO THE QUOTE TOKEN, BY CONSTRUCTION. ────────────────────
// Launch FDV = virtual_quote_v4 quote base units, whatever USDCx is worth in
// ADA. A different quote token, scale or fee is a NEW COHORT (new hashes).
// ══════════════════════════════════════════════════════════════════════════════

use aiken/builtin

/// Genesis supply, and the supply forever. Whole units, 0 decimals.
pub const total_supply_v4: Int = 1_000_000_000

/// V — the virtual quote reserve, in quote BASE units (USDCx has 6 decimals),
/// present for life. 350,000,000 base units = 350 USDCx: launch FDV = 350 USDCx,
/// launch price = 7/20 of a base unit per token (one million tokens cost
/// 0.35 USDCx). Sized 2026-09-26 to match the LUMP cohort's launch FDV in ADA
/// terms (10M LUMP ≈ 1,282 ₳; 350 USDCx ≈ 1,378 ₳ at 3.94 ₳/USDCx).
/// THE SINGLE SCALE KNOB: quote needed to reach a multiple m of launch FDV is
/// V·(√m − 1) — 10x ≈ 757 USDCx, 100x ≈ 3,150 USDCx.
pub const virtual_quote_v4: Int = 350_000_000

/// Lovelace the pool UTxO carries for its whole life. NOT part of the price and
/// never paid out — the ledger's min-UTxO for an output holding four assets and
/// an 11-field inline datum. Pinned EXACTLY at genesis and on every continuation.
pub const pool_floor_v4: Int = 3_000_000

/// 1.00% of the quote leg to the creator on every trade, accrued to
/// `creator_owed`. The creator's ONLY allocation — there is no free supply.
pub const creator_fee_bps_v4: Int = 100

/// 0.50% of the quote leg to the platform on every trade.
pub const platform_fee_bps_v4: Int = 50

/// 350,000 base units = 0.35 USDCx flat per trade to the platform, on top of
/// the bps above (the LUMP cohort's 10,000 LUMP flat, in ADA terms — 1/1000 of
/// the launch FDV).
pub const platform_fee_flat_v4: Int = 350_000

/// 0.30% LP fee retained IN the reserves on every trade (Uniswap-V2 convention).
/// No LP tokens, no withdraw path: permanent depth, k strictly grows.
pub const lp_fee_bps_v4: Int = 30

/// ██ THE QUOTE ASSET — $USDCx (USDC on Cardano via Circle xReserve). COMPILED IN. ██
/// policy 1f3aec8b…ac7e34, asset name "USDCx" (0x5553444378), 6 decimals.
pub const quote_policy_v4: ByteArray =
  #"1f3aec8bfe7ea4fe14c5f121e2a92e301afe414147860d557cac7e34"

pub const quote_name_v4: ByteArray = #"5553444378"

/// ██ THE LUMPPAD TREASURY. ██ The SAME dedicated LumpPad treasury key as every
/// earlier cohort — LUMP, NIGHT, DONG, PUFFLE, ALIENS (base address
/// addr1q8res39g…3x40, operator-controlled). Fee RECIPIENT only — it signs
/// nothing on trades and cannot spend a pool; on this cohort its signature (or
/// the creator's) is what authorises a Claim.
pub const treasury_pkh_v4: ByteArray =
  #"c79844a83ab36100765fbc19fb8d738a0d46657708f6ad08c8c637f3"

/// ██ THE LUMP BUYBACK KEY. ██ Payment key hash of the dedicated LumpPad buyback
/// wallet (base address addr1qyz3aa4w…hp2x, operator-controlled) — the SAME key
/// the NIGHT, DONG, PUFFLE and ALIENS cohorts pay: one buyback wallet serves
/// every non-LUMP cohort. `Claim` pays `platform_owed / 2` here on every claim;
/// the operator buys LUMP with it and burns that. Compiled into the pool script,
/// so rotating it is a new cohort. Distinct from the treasury by construction —
/// `pays_quote_at_least` is existential, so the two recipients of a claim must
/// never share a credential.
pub const buyback_pkh_v4: ByteArray =
  #"051ef6ae7c8c2d1d1dd78601cdcc097c28bf617ba621ea47c1d111bb"

// ── Identity tests ────────────────────────────────────────────────────────────

/// Launch price is exactly 7/20 of a base unit per token (V × 20 = 7 × S):
/// one million tokens cost 350,000 base units = 0.35 USDCx at launch.
test params_launch_price_is_seven_twentieths_base_unit_per_token() {
  virtual_quote_v4 * 20 == 7 * total_supply_v4
}

test params_quote_policy_is_28_bytes() {
  builtin.length_of_bytearray(quote_policy_v4) == 28
}

test params_treasury_is_28_bytes() {
  builtin.length_of_bytearray(treasury_pkh_v4) == 28
}

test params_buyback_is_28_bytes_and_not_the_treasury() {
  builtin.length_of_bytearray(buyback_pkh_v4) == 28 && buyback_pkh_v4 != treasury_pkh_v4
}

/// The on-chain asset name is "USDCx" (mixed case) — exactly the ticker people read.
test params_quote_name_is_usdcx() {
  quote_name_v4 == "USDCx"
}

/// The flat fee is strictly positive: `platform_fee` is never zero.
test params_flat_fee_positive() {
  platform_fee_flat_v4 > 0
}

/// The flat fee is 0.1% of the launch FDV — the same proportion as the LUMP cohort.
test params_flat_fee_is_one_thousandth_of_launch_fdv() {
  platform_fee_flat_v4 * 1_000 == virtual_quote_v4
}

test params_fee_bounds() {
  and {
    creator_fee_bps_v4 >= 0,
    creator_fee_bps_v4 <= 10_000,
    platform_fee_bps_v4 >= 0,
    platform_fee_bps_v4 <= 10_000,
    lp_fee_bps_v4 > 0,
    lp_fee_bps_v4 < 10_000,
  }
}
