// ══════════════════════════════════════════════════════════════════════════════
// LumpFun v4 / LumpPad — the QUOTE-ASSET cohort. Every constant is denominated
// in the quote token (LUMP), never in ADA. ADA appears in exactly one place: the
// fixed min-UTxO floor the pool UTxO must carry so the ledger accepts it.
//
// ── ONE PHASE. NO GRADUATION. ─────────────────────────────────────────────────
// The pool is a constant-product AMM from the first block, priced on
// `quote_reserve + virtual_quote_v4`, and its real quote balance grows with
// every net buy plus the LP fee retained in the reserves. There is no mode, no
// pool bag, no curve exhaustion, no bounty, and nothing to graduate. The
// launcher seeds NO quote asset: `quote_reserve` is 0 at genesis unless the
// launch carries a genesis buy, which is priced like any other buy.
//
// ── FEES ACCRUE INSIDE THE POOL. ──────────────────────────────────────────────
// A fee OUTPUT in the quote token would have to carry its own min-UTxO on every
// trade, so a trade adds its fees to `platform_owed` / `creator_owed` in the
// datum instead; the pool's quote balance is pinned to reserve + both counters,
// and `Claim` pays them out. HALF of the platform take is paid to the burn
// script (`burn_script_hash_v4`) — enforced by the validator, not by policy.
//
// ── SCALE IS RELATIVE TO THE QUOTE TOKEN, BY CONSTRUCTION. ────────────────────
// Launch FDV = virtual_quote_v4 quote units, whatever the quote token is worth
// in ADA. A different quote token, scale or fee is a NEW COHORT (new hashes).
// ══════════════════════════════════════════════════════════════════════════════

use aiken/builtin

/// Genesis supply, and the supply forever. Whole units, 0 decimals — the
/// memecoin convention (pump.fun, snek.fun, four.meme) and $LUMP's own.
pub const total_supply_v4: Int = 1_000_000_000

/// V — the virtual quote reserve, in quote units (LUMP), present for life.
/// Launch FDV = 10,000,000 LUMP = 1% of LUMP's supply; launch price = 0.01
/// LUMP per token. THE SINGLE SCALE KNOB: quote needed to reach a multiple m
/// of launch FDV is V·(√m − 1) — 10x ≈ 21.6M LUMP, 100x ≈ 90M LUMP.
/// Operator decision 2026-09-12.
pub const virtual_quote_v4: Int = 10_000_000

/// Lovelace the pool UTxO carries for its whole life. NOT part of the price and
/// never paid out — the ledger's min-UTxO for an output holding four assets and
/// an 11-field inline datum (measured worst case ≈ 2.3 ADA; 3 ADA leaves
/// headroom). Pinned EXACTLY at genesis and on every continuation.
pub const pool_floor_v4: Int = 3_000_000

/// 1.00% of the quote leg to the creator on every trade, accrued to
/// `creator_owed`. The creator's ONLY allocation — there is no free supply.
pub const creator_fee_bps_v4: Int = 100

/// 0.50% of the quote leg to the platform on every trade. Operator decision
/// 2026-09-12: a flat fee alone does not scale with volume, and half of the
/// platform take is burned, so the burn must scale too.
pub const platform_fee_bps_v4: Int = 50

/// 10,000 LUMP flat per trade to the platform, on top of the bps above.
pub const platform_fee_flat_v4: Int = 10_000

/// 0.30% LP fee retained IN the reserves on every trade (Uniswap-V2 convention).
/// No LP tokens, no withdraw path: permanent depth, k strictly grows.
pub const lp_fee_bps_v4: Int = 30

/// ██ THE QUOTE ASSET — $LUMP. COMPILED IN. ██
/// policy 73797786…ad2c, asset name "Lump" (0x4c756d70), 0 decimals.
pub const quote_policy_v4: ByteArray =
  #"73797786382c0832b5787a5b306f5308488f14571b7061f79396ad2c"

pub const quote_name_v4: ByteArray = #"4c756d70"

/// ██ THE LUMPPAD TREASURY. ██ Payment key hash of the dedicated LumpPad
/// treasury wallet (base address addr1q8res39g…3x40, operator-controlled).
/// Fee RECIPIENT only — it signs nothing and
/// cannot spend a pool. Distinct from LumpFun's v3 treasury on purpose: LumpPad
/// is a separate product with its own books. Compiled into both scripts, so
/// rotating it is a new cohort.
pub const treasury_pkh_v4: ByteArray =
  #"c79844a83ab36100765fbc19fb8d738a0d46657708f6ad08c8c637f3"

/// ██ THE BURN. ██ Script hash of `validators/burn.ak` (`lump_burn`, always
/// fails). `Claim` pays `platform_owed / 2` here on every claim. Pinned in
/// hashes.expected; the protocol generator asserts this constant equals the
/// compiled burn script's hash, so the two cannot drift.
pub const burn_script_hash_v4: ByteArray =
  #"22c9a103ed3f2fa97c982d76d6e2af50c5d54ac306983b196c8fcdab"

// ── Identity tests ────────────────────────────────────────────────────────────

/// Launch price is exactly 1/100 quote per token.
test params_launch_price_is_one_hundredth_quote_per_token() {
  virtual_quote_v4 * 100 == total_supply_v4
}

test params_quote_policy_is_28_bytes() {
  builtin.length_of_bytearray(quote_policy_v4) == 28
}

test params_treasury_is_28_bytes() {
  builtin.length_of_bytearray(treasury_pkh_v4) == 28
}

test params_burn_is_28_bytes_and_not_the_treasury() {
  builtin.length_of_bytearray(burn_script_hash_v4) == 28 && burn_script_hash_v4 != treasury_pkh_v4
}

test params_quote_name_is_lump() {
  quote_name_v4 == "Lump"
}

/// The flat fee is strictly positive: `platform_fee` is never zero.
test params_flat_fee_positive() {
  platform_fee_flat_v4 > 0
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
