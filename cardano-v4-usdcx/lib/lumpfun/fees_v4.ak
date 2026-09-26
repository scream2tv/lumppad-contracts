// ── LumpFun v4 (USDCx cohort) — fee arithmetic (quote units) and the Claim payout check ─
//
// Trades do NOT produce fee outputs. `lump_pool.validate_buy/sell` add the fee
// to the datum's owed counters and the value invariant pins the pool's quote
// balance to `quote_reserve + platform_owed + creator_owed`, so the fee is
// physically in the pool from the moment it is charged. `Claim` is the only
// branch that pays anything to anyone, and `pays_quote_at_least` is its check.
//
// BUY  fees are a SURCHARGE on `quote_in` (the amount that reaches the reserve);
//      the trader deposits `quote_in + fees`.
// SELL fees are DEDUCTED from `gross`; the trader receives `sell_net`.
// CLAIM pays `burn_share(platform_owed)` to the BUYBACK key and the rest to the
//      treasury; `creator_owed` to the creator credential.
//
// ── H-1 (2026-09-12 review) CLOSED IN THIS COHORT ─────────────────────────────
// The LUMP cohort's `pays_quote_at_least` accepted a payout at a SCRIPT address
// whose hash equals the recipient's KEY hash — an address nobody can spend from
// — so anyone could claim and strand the treasury's or a key creator's share.
// Here every recipient is a verification key and a Script credential NEVER
// matches, whatever its hash.

use aiken/collection/list
use cardano/address.{Credential}
use cardano/assets.{quantity_of}
use cardano/transaction.{NoDatum, Output}
use lumpfun/params_v4.{quote_name_v4, quote_policy_v4}

pub fn creator_fee(amount: Int, bps: Int) -> Int {
  amount * bps / 10_000
}

/// Strictly positive because `flat` is.
pub fn platform_fee(amount: Int, bps: Int, flat: Int) -> Int {
  amount * bps / 10_000 + flat
}

pub fn sell_net(gross: Int, creator_bps: Int, platform_bps: Int, flat: Int) -> Int {
  gross - creator_fee(gross, creator_bps) - platform_fee(gross, platform_bps, flat)
}

/// The buyback half of a platform claim (floor; the treasury gets the odd unit).
pub fn burn_share(platform_owed: Int) -> Int {
  platform_owed / 2
}

/// True when some output pays at least `min_qty` of the quote asset to an
/// address whose PAYMENT credential is the VERIFICATION KEY `pkh`. A script
/// credential is never a match — so the pool's own continuation can never
/// satisfy a payout, and a key recipient can never be paid to an unspendable
/// script address of the same hash.
///
/// Existential, and exact only because `lump_pool.tx_shape_ok` admits ONE pool
/// per transaction and the recipients checked in one claim are DISTINCT
/// credentials (`pool_seeded` pins creator != treasury; the buyback key is a
/// constant unequal to the treasury; a creator EQUAL to the buyback key is
/// folded into one combined requirement by `validate_claim`).
pub fn pays_quote_at_least(outputs: List<Output>, pkh: ByteArray, min_qty: Int) -> Bool {
  list.any(
    outputs,
    fn(o) {
      when o.address.payment_credential is {
        Credential.VerificationKey(h) ->
          h == pkh && quantity_of(o.value, quote_policy_v4, quote_name_v4) >= min_qty
        Credential.Script(_) -> False
      }
    },
  )
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const f_pkh: ByteArray =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

const f_pool: ByteArray =
  #"d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0"

fn quote_out_key(pkh: ByteArray, qty: Int) -> Output {
  Output {
    address: address.from_verification_key(pkh),
    value: assets.from_lovelace(1_200_000)
      |> assets.add(quote_policy_v4, quote_name_v4, qty),
    datum: NoDatum,
    reference_script: None,
  }
}

fn quote_out_script(h: ByteArray, qty: Int) -> Output {
  Output {
    address: address.from_script(h),
    value: assets.from_lovelace(1_200_000)
      |> assets.add(quote_policy_v4, quote_name_v4, qty),
    datum: NoDatum,
    reference_script: None,
  }
}

test creator_fee_one_percent() {
  creator_fee(3_500_000, 100) == 35_000
}

test creator_fee_floors_to_zero_under_100() {
  creator_fee(99, 100) == 0
}

test platform_fee_is_bps_plus_flat() {
  platform_fee(3_500_000, 50, 350_000) == 367_500
}

test platform_fee_dust_is_the_flat() {
  platform_fee(1, 50, 350_000) == 350_000
}

test sell_net_worked() {
  sell_net(3_500_000, 100, 50, 350_000) == 3_097_500
}

test burn_share_halves_and_floors() {
  burn_share(367_500) == 183_750 && burn_share(367_501) == 183_750 && burn_share(1) == 0
}

test pays_quote_accepts_exact() {
  pays_quote_at_least([quote_out_key(f_pkh, 350_000)], f_pkh, 350_000)
}

test pays_quote_accepts_more() {
  pays_quote_at_least([quote_out_key(f_pkh, 350_001)], f_pkh, 350_000)
}

test pays_quote_rejects_less() {
  !pays_quote_at_least([quote_out_key(f_pkh, 349_999)], f_pkh, 350_000)
}

test pays_quote_rejects_wrong_recipient() {
  !pays_quote_at_least([quote_out_key(f_pool, 350_000)], f_pkh, 350_000)
}

/// H-1: the SAME hash at a script address is not a payout to the key.
test pays_quote_rejects_script_credential_of_same_hash() {
  !pays_quote_at_least([quote_out_script(f_pkh, 350_000)], f_pkh, 350_000)
}

test pays_quote_rejects_lovelace_only() {
  let o =
    Output {
      address: address.from_verification_key(f_pkh),
      value: assets.from_lovelace(50_000_000),
      datum: NoDatum,
      reference_script: None,
    }
  !pays_quote_at_least([o], f_pkh, 1)
}
