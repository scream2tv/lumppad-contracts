// ══════════════════════════════════════════════════════════════════════════════
// LumpFun v4 — pool datum & redeemer (QUOTE-ASSET cohort, ALIENS edition)
//
// ONE state. The pool is a constant-product AMM with a permanent virtual quote
// offset (`params_v4.virtual_quote_v4`). There is no mode, no flip, nothing to
// graduate: `Buy` and `Sell` are the only trades and they work identically on
// the first block and the millionth.
//
// ── FEES LIVE IN THE DATUM ───────────────────────────────────────────────────
// `platform_owed` / `creator_owed` are running totals in quote units. The pool
// UTxO's quote balance is pinned to `quote_reserve + platform_owed +
// creator_owed` on every spend, so the owed amounts are REAL tokens sitting in
// the pool that the price does not see. `Claim` pays them out and zeroes both.
// ══════════════════════════════════════════════════════════════════════════════

use aiken/builtin
use aiken/collection/list

/// Reserved asset name for the pool-authenticity NFT: CIP-67 label 100 ‖ "POOL".
/// Minted 1-of-1 by the same one-shot policy as the token and required in the
/// pool UTxO on every spend. Same constant as v2/v3 — identity comes from the
/// (policy, NFT) pair, not the name.
pub const pool_nft_name: ByteArray = #"000643b0504f4f4c"

/// Inline datum on every v4 pool UTxO.
///
/// ── CONSTRUCTOR INDEX 2 ──────────────────────────────────────────────────────
/// Index 0 is v2's `PoolDatum`, index 1 is v3's `PoolDatumV3`; both are
/// occupied by nullary reserved constructors here so a v4 datum is `Constr(2,
/// [11 fields])` on the wire and no reader keyed on tag OR arity can confuse the
/// three. `v4_datum_wire_shape_is_constr_two_with_eleven_fields` pins it.
///
/// ── WHAT THE RESERVES MEAN ───────────────────────────────────────────────────
///   quantity_of(value, quote)          == quote_reserve + platform_owed + creator_owed
///   quantity_of(value, policy, name)   == token_reserve            (REAL, no offset)
///   lovelace_of(value)                 == pool_floor_v4            (constant, for life)
///   quantity_of(value, policy, NFT)    == 1
///
/// Price is `(quote_reserve + virtual_quote_v4) / token_reserve`. The offset is
/// in the MATH, never in the value.
pub type PoolDatum {
  /// Index 0 — reserved (v2 wire slot). Never constructed.
  ReservedV2Slot
  /// Index 1 — reserved (v3 wire slot). Never constructed.
  ReservedV3Slot
  /// Index 2 — the live v4 pool datum.
  PoolDatumV4 {
    /// One-shot policy id of BOTH the token and the pool NFT (28 bytes).
    policy_id: ByteArray,
    /// Token asset name.
    asset_name: ByteArray,
    /// MUTABLE. Real quote units the PRICE sees. Starts at 0 (or the genesis
    /// buy). Excludes the owed fees below.
    quote_reserve: Int,
    /// MUTABLE. Real token balance of the pool UTxO.
    token_reserve: Int,
    /// MUTABLE. Platform fees accrued and not yet claimed, quote units.
    platform_owed: Int,
    /// MUTABLE. Creator fees accrued and not yet claimed, quote units.
    creator_owed: Int,
    /// FROZEN. Creator fee recipient KEY hash (28 bytes). A creator equal to the
    /// buyback key routes its fee to the LUMP buyback (this cohort pays keys only).
    creator_pkh: ByteArray,
    /// FROZEN. Treasury credential — pinned to `treasury_pkh_v4`.
    treasury_pkh: ByteArray,
    /// FROZEN. Pinned to the cohort constants at genesis.
    creator_fee_bps: Int,
    platform_fee_bps: Int,
    platform_fee_flat: Int,
  }
}

/// v4 pool redeemer. Wire: Buy = Constr 0, Sell = Constr 1, Claim = Constr 2.
pub type PoolRedeemer {
  /// Quote in, tokens out. `min_out` = token slippage floor.
  Buy { min_out: Int }
  /// Tokens in, quote out. `min_out` = NET quote slippage floor (after fees).
  Sell { min_out: Int }
  /// Pay half of `platform_owed` to the buyback key and half to the treasury,
  /// `creator_owed` to the creator; zero both counters. Reserves untouched.
  /// Must be SIGNED by the creator or the treasury key (this cohort); the money
  /// can only go to the pinned verification-key credentials.
  Claim
}

/// ██ R-5 — WHOLE-DATUM RECONSTRUCTION. ██
/// The pool is unparameterised, so every config field lives in the datum. Every
/// branch that writes a continuation asserts `with_state(d, …) == new_d`: the
/// four mutable fields are supplied, the seven config fields are copied from the
/// INPUT datum, and the equality freezes them for life. Aiken forbids record
/// update on multi-constructor types, so this is the only way to write it — and
/// adding a field breaks this function at compile time.
pub fn with_state(
  d: PoolDatum,
  quote_reserve: Int,
  token_reserve: Int,
  platform_owed: Int,
  creator_owed: Int,
) -> PoolDatum {
  expect PoolDatumV4 {
    policy_id,
    asset_name,
    creator_pkh,
    treasury_pkh,
    creator_fee_bps,
    platform_fee_bps,
    platform_fee_flat,
    ..
  } = d
  PoolDatumV4 {
    policy_id,
    asset_name,
    quote_reserve,
    token_reserve,
    platform_owed,
    creator_owed,
    creator_pkh,
    treasury_pkh,
    creator_fee_bps,
    platform_fee_bps,
    platform_fee_flat,
  }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

fn sample() -> PoolDatum {
  PoolDatumV4 {
    policy_id: #"a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0",
    asset_name: #"4167656e74",
    quote_reserve: 100_000,
    token_reserve: 990_128_420,
    platform_owed: 10_500,
    creator_owed: 1_000,
    creator_pkh: #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0",
    treasury_pkh: #"a32f8cb5575fc688ee8dc838509413987f10e41528a17002a3b64542",
    creator_fee_bps: 100,
    platform_fee_bps: 50,
    platform_fee_flat: 10_000,
  }
}

/// The ONLY test that fails if someone deletes a reserved constructor.
test v4_datum_wire_shape_is_constr_two_with_eleven_fields() {
  let d: Data = sample()
  let Pair(tag, fields) = builtin.un_constr_data(d)
  tag == 2 && list.length(fields) == 11
}

test v4_reserved_slots_are_tags_zero_and_one() {
  let a: Data = ReservedV2Slot
  let b: Data = ReservedV3Slot
  let Pair(ta, fa) = builtin.un_constr_data(a)
  let Pair(tb, fb) = builtin.un_constr_data(b)
  ta == 0 && fa == [] && tb == 1 && fb == []
}

test v4_redeemer_wire_tags() {
  let b: Data = Buy { min_out: 7 }
  let s: Data = Sell { min_out: 7 }
  let c: Data = Claim
  let Pair(tb, _) = builtin.un_constr_data(b)
  let Pair(ts, _) = builtin.un_constr_data(s)
  let Pair(tc, fc) = builtin.un_constr_data(c)
  tb == 0 && ts == 1 && tc == 2 && fc == []
}

test with_state_moves_exactly_the_four_mutable_fields() {
  let d = sample()
  let n = with_state(d, 1, 2, 3, 4)
  expect PoolDatumV4 {
    policy_id,
    asset_name,
    quote_reserve,
    token_reserve,
    platform_owed,
    creator_owed,
    creator_pkh,
    treasury_pkh,
    creator_fee_bps,
    platform_fee_bps,
    platform_fee_flat,
  } = n
  and {
    quote_reserve == 1,
    token_reserve == 2,
    platform_owed == 3,
    creator_owed == 4,
    policy_id == #"a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0",
    asset_name == #"4167656e74",
    creator_pkh == #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0",
    treasury_pkh == #"a32f8cb5575fc688ee8dc838509413987f10e41528a17002a3b64542",
    creator_fee_bps == 100,
    platform_fee_bps == 50,
    platform_fee_flat == 10_000,
  }
}

test with_state_identity_roundtrip() {
  let d = sample()
  with_state(d, 100_000, 990_128_420, 10_500, 1_000) == d
}
