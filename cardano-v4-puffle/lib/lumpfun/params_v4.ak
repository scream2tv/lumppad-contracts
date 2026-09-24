// ══════════════════════════════════════════════════════════════════════════════
// LumpFun v4 / LumpPad — the PUFFLE-QUOTED cohort. Every constant is denominated
// in the quote token ($PUFFLE, 0 decimals → whole units), never in ADA. ADA appears
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
// ── THE "BURN HALF" IS A LUMP BUYBACK, NOT A PUFFLE BURN. ─────────────────────
// On the LUMP cohort half of the platform fee is paid to an always-fail script,
// destroying LUMP for good. Destroying PUFFLE would do nothing for $LUMP holders,
// so on this cohort that half is paid to a dedicated BUYBACK key
// (`buyback_pkh_v4`): the operator buys LUMP with it and burns that by hand.
// The split itself (platform_owed / 2) is still enforced on chain.
//
// ── ONE PHASE. NO GRADUATION. FEES ACCRUE INSIDE THE POOL. ────────────────────
// Unchanged from the LUMP cohort — see its own `params_v4.ak`.
//
// ── SCALE IS RELATIVE TO THE QUOTE TOKEN, BY CONSTRUCTION. ────────────────────
// Launch FDV = virtual_quote_v4 quote units, whatever PUFFLE is worth in ADA. A
// different quote token, scale or fee is a NEW COHORT (new hashes).
// ══════════════════════════════════════════════════════════════════════════════

use aiken/builtin

/// Genesis supply, and the supply forever. Whole units, 0 decimals.
pub const total_supply_v4: Int = 1_000_000_000

/// V — the virtual quote reserve, in whole PUFFLE (0 decimals), present for life.
/// 30,000,000 PUFFLE: launch FDV = 30,000,000 PUFFLE, launch price = 3/100 PUFFLE
/// (0.03 PUFFLE) per token. Sized 2026-09-24 to match the LUMP cohort's launch
/// FDV in ADA terms (10M LUMP ≈ 1,244 ₳; 30M PUFFLE ≈ 1,333 ₳ at 0.0000444 ₳/PUFFLE).
/// THE SINGLE SCALE KNOB: quote needed to reach a multiple m of launch FDV is
/// V·(√m − 1) — 10x ≈ 64.9M PUFFLE, 100x ≈ 270M PUFFLE.
pub const virtual_quote_v4: Int = 30_000_000

/// Lovelace the pool UTxO carries for its whole life. NOT part of the price and
/// never paid out — the ledger's min-UTxO for an output holding four assets and
/// an 11-field inline datum. Pinned EXACTLY at genesis and on every continuation.
pub const pool_floor_v4: Int = 3_000_000

/// 1.00% of the quote leg to the creator on every trade, accrued to
/// `creator_owed`. The creator's ONLY allocation — there is no free supply.
pub const creator_fee_bps_v4: Int = 100

/// 0.50% of the quote leg to the platform on every trade.
pub const platform_fee_bps_v4: Int = 50

/// 30,000 PUFFLE flat per trade to the platform, on top of the bps above (the LUMP
/// cohort's 10,000 LUMP flat, in ADA terms — 1/1000 of the launch FDV).
pub const platform_fee_flat_v4: Int = 30_000

/// 0.30% LP fee retained IN the reserves on every trade (Uniswap-V2 convention).
/// No LP tokens, no withdraw path: permanent depth, k strictly grows.
pub const lp_fee_bps_v4: Int = 30

/// ██ THE QUOTE ASSET — $PUFFLE. COMPILED IN. ██
/// policy ea2eb3d9…46638f, asset name "Puffle" (0x507566666c65), 0 decimals.
pub const quote_policy_v4: ByteArray =
  #"ea2eb3d9223e355d38f6d68b902288e9ca8c2b7977e1d0f80a46638f"

pub const quote_name_v4: ByteArray = #"507566666c65"

/// ██ THE LUMPPAD TREASURY. ██ The SAME dedicated LumpPad treasury key as the
/// LUMP, NIGHT and DONG cohorts (base address addr1q8res39g…3x40, operator-controlled).
/// Fee RECIPIENT only — it signs nothing on trades and cannot spend a pool; on
/// this cohort its signature (or the creator's) is what authorises a Claim.
pub const treasury_pkh_v4: ByteArray =
  #"c79844a83ab36100765fbc19fb8d738a0d46657708f6ad08c8c637f3"

/// ██ THE LUMP BUYBACK KEY. ██ Payment key hash of the dedicated LumpPad buyback
/// wallet (base address addr1qyz3aa4w…hp2x, operator-controlled) — the SAME key
/// the NIGHT and DONG cohorts pay: one buyback wallet serves every non-LUMP cohort. `Claim`
/// pays `platform_owed / 2` here on every claim; the operator buys LUMP with it
/// and burns that. Compiled into the pool script, so rotating it is a new cohort.
/// Distinct from the treasury by construction — `pays_quote_at_least` is
/// existential, so the two recipients of a claim must never share a credential.
pub const buyback_pkh_v4: ByteArray =
  #"051ef6ae7c8c2d1d1dd78601cdcc097c28bf617ba621ea47c1d111bb"

// ── Identity tests ────────────────────────────────────────────────────────────

/// Launch price is exactly 3/100 PUFFLE per token (V × 100 = 3 × S).
test params_launch_price_is_three_hundredths_per_token() {
  virtual_quote_v4 * 100 == 3 * total_supply_v4
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

/// The on-chain asset name is "Puffle" (mixed case) — the ticker people read is PUFFLE.
test params_quote_name_is_puffle() {
  quote_name_v4 == "Puffle"
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
