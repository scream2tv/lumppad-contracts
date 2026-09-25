// ══════════════════════════════════════════════════════════════════════════════
// LumpFun v4 (ALIENS cohort) — constant-product quotes with a PERMANENT virtual
// quote offset. Byte-for-byte the LUMP, NIGHT and DONG cohorts' math; only the
// worked vectors below are re-derived for V = 40,000,000 (whole ALIENS, 0 decimals).
//
//     effective = quote_reserve + virtual_quote_v4
//     k         = effective × token_reserve
//
// Uniswap-V2 fee convention on BOTH sides: the quote prices the input NET of
// the LP fee, the FULL input enters the reserve, so k strictly grows on every
// trade. The offset never leaves: a sell is capped at the REAL reserve, and
// constant-product path independence guarantees the real reserve is never asked
// for more than it holds (a sell can only return what buys put in, minus fees).
//
// The off-chain quoter (web/) must reproduce this integer arithmetic exactly —
// the validator demands equality, not tolerance.
//
//   Worked genesis vectors (V = 40,000,000, S = 1e9, lp = 30 bps), whole ALIENS:
//     buy 400,000 ALIENS   → net 398,800   → ⌊398,800   × 1e9 / 40,398,800⌋ = 9,871,580
//     buy 40,000 ALIENS    → net 39,880    → ⌊39,880    × 1e9 / 40,039,880⌋ = 996,006
//     buy 4,000,000 ALIENS → net 3,988,000 → ⌊3,988,000 × 1e9 / 43,988,000⌋ = 90,661,089
//   (identical token counts to the LUMP cohort's 100,000 / 10,000 / 1,000,000 LUMP
//    buys: every quote figure is ×3, the ratio to V is unchanged.)
// ══════════════════════════════════════════════════════════════════════════════

use lumpfun/params_v4.{lp_fee_bps_v4, total_supply_v4, virtual_quote_v4}

pub fn effective_quote(quote_reserve: Int) -> Int {
  quote_reserve + virtual_quote_v4
}

/// Input net of the LP fee, floor division (the pool keeps the dust).
pub fn net_of_lp_fee(amount: Int) -> Int {
  amount * ( 10_000 - lp_fee_bps_v4 ) / 10_000
}

/// Tokens out for `quote_in` quote units. Floors the amount OUT, so
/// `tokens_out < token_reserve` at every state (the pool always keeps ≥ 1 token).
pub fn quote_buy(quote_reserve: Int, token_reserve: Int, quote_in: Int) -> Int {
  let net = net_of_lp_fee(quote_in)
  net * token_reserve / ( effective_quote(quote_reserve) + net )
}

/// GROSS quote out for `tokens_in`, before the platform/creator fees, capped at
/// the REAL reserve so the pool can never be asked to pay virtual quote.
pub fn quote_sell_gross(
  quote_reserve: Int,
  token_reserve: Int,
  tokens_in: Int,
) -> Int {
  let net = net_of_lp_fee(tokens_in)
  let gross = net * effective_quote(quote_reserve) / ( token_reserve + net )
  if gross > quote_reserve {
    quote_reserve
  } else {
    gross
  }
}

pub fn k_value(quote_reserve: Int, token_reserve: Int) -> Int {
  effective_quote(quote_reserve) * token_reserve
}

// ── Tests — every number re-derived from params_v4 ────────────────────────────

test buy_genesis_400000_aliens() {
  quote_buy(0, total_supply_v4, 400_000) == 9_871_580
}

test buy_genesis_40000_aliens() {
  quote_buy(0, total_supply_v4, 40_000) == 996_006
}

test buy_genesis_4000000_aliens() {
  quote_buy(0, total_supply_v4, 4_000_000) == 90_661_089
}

/// Launch price is 1/25 ALIENS per token: 40,000 ALIENS buys strictly fewer than 1M.
test buy_genesis_price_is_just_above_three_hundredths() {
  quote_buy(0, total_supply_v4, 40_000) < 1_000_000
}

test buy_of_zero_is_zero() {
  quote_buy(0, total_supply_v4, 0) == 0
}

test buy_dust_5000_aliens() {
  // 5,000 → net 4,985 → ⌊4,985e9 / 40,004,985⌋ = 124,609
  quote_buy(0, total_supply_v4, 5_000) == 124_609
}

test buy_dust_five_aliens() {
  // 5 → net 4 → ⌊4e9 / 40,000,004⌋ = 99
  quote_buy(0, total_supply_v4, 5) == 99
}

/// One ALIENS nets to zero after the LP fee and buys nothing at launch.
test buy_dust_one_aliens_is_zero() {
  quote_buy(0, total_supply_v4, 1) == 0
}

/// The pool can never be emptied of tokens by a buy: out < reserve always.
test buy_never_empties_token_side() {
  quote_buy(0, total_supply_v4, 1_000_000_000_000_000) < total_supply_v4
}

/// After the 400,000 ALIENS genesis buy the state is (400,000, 990,128,420).
/// Selling the 9,871,580 back: net 9,841,965 → ⌊… × 40,400,000 / 999,970,385⌋ = 397,627 gross.
test sell_roundtrip_after_400000_aliens_buy() {
  quote_sell_gross(400_000, 990_128_420, 9_871_580) == 397_627
}

/// Round trip loses to the LP fee (twice) and rounding, never gains.
test sell_roundtrip_never_returns_more_than_paid() {
  quote_sell_gross(400_000, 990_128_420, 9_871_580) < 400_000
}

test sell_at_genesis_pays_nothing() {
  quote_sell_gross(0, total_supply_v4, 1_000) == 0
}

test sell_is_capped_at_real_reserve() {
  quote_sell_gross(10, 999_999, 1_000) == 10
}

test sell_of_zero_is_zero() {
  quote_sell_gross(400_000, 990_128_420, 0) == 0
}

test k_grows_across_a_buy() {
  let out = quote_buy(0, total_supply_v4, 400_000)
  k_value(400_000, total_supply_v4 - out) > k_value(0, total_supply_v4)
}

test k_grows_across_a_sell() {
  let gross = quote_sell_gross(400_000, 990_128_420, 9_871_580)
  k_value(400_000 - gross, 990_128_420 + 9_871_580) > k_value(400_000, 990_128_420)
}

test net_of_lp_fee_floors() {
  net_of_lp_fee(10_000) == 9_970 && net_of_lp_fee(1) == 0
}
