use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Credential}
use cardano/assets.{Value, flatten, lovelace_of, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use lumpfun/fees_v4.{
  burn_share, creator_fee, pays_quote_at_least, platform_fee, sell_net,
}
use lumpfun/math_v4.{quote_buy, quote_sell_gross}
use lumpfun/params_v4.{
  buyback_pkh_v4, platform_fee_bps_v4, platform_fee_flat_v4, pool_floor_v4,
  quote_name_v4, quote_policy_v4, total_supply_v4, treasury_pkh_v4,
}
use lumpfun/pool_types.{
  Buy, Claim, PoolDatum, PoolDatumV4, PoolRedeemer, Sell, pool_nft_name,
  with_state,
}
use lumpfun/test_helpers.{input_of, oref, pk_out, script_out, script_out_staked}

// ══════════════════════════════════════════════════════════════════════════════
// LumpFun v4 / LumpPad pool validator — NIGHT-QUOTED cohort. UNPARAMETERISED,
// ONE MODE, ONE ADDRESS, QUOTED IN $NIGHT (params_v4.quote_policy_v4 / quote_name_v4).
//
// Descended from the LUMP cohort (`cardano-v4/validators/lump_pool.ak`).
// The Buy and Sell branches are byte-for-byte that validator's. What changed:
//
//   • THE "BURN HALF" IS A LUMP BUYBACK. `Claim` pays `platform_owed / 2` to
//     the buyback KEY (`params_v4.buyback_pkh_v4`) instead of an always-fail
//     script: destroying NIGHT would do nothing for $LUMP; the operator buys
//     and burns LUMP with it. The on-chain split is the same.
//   • H-1 CLOSED. `Claim` must be SIGNED by the creator or the treasury key,
//     and every payout must land at a VERIFICATION-KEY credential
//     (fees_v4.pays_quote_at_least refuses script credentials). In the LUMP
//     cohort anyone could claim and pay a key recipient's share to the script
//     address of the same hash — unspendable forever.
//
// What did NOT change, and must not: R-3 tx-shape confinement, the NFT
// authenticity check, V-6 in/out value consistency, R-5 whole-datum
// reconstruction on every branch, sole-continuation at the exact address, no
// reference script, value-shape pin, no mint under the pool's policy, the
// platform fee schedule pinned at spend time, and ██ NO WITHDRAW BRANCH ██.
// Liquidity is locked for life. The only way quote leaves the pool is `Sell`
// at the pool's own price and `Claim` of fees already charged to traders.
// ══════════════════════════════════════════════════════════════════════════════

validator lump_pool_v4 {
  spend(
    datum: Option<PoolDatum>,
    redeemer: PoolRedeemer,
    utxo: OutputReference,
    tx: Transaction,
  ) {
    expect Some(d) = datum
    expect PoolDatumV4 {
      policy_id,
      asset_name,
      quote_reserve,
      token_reserve,
      platform_owed,
      creator_owed,
      ..
    } = d

    expect Some(own_input) =
      list.find(tx.inputs, fn(i) { i.output_reference == utxo })

    expect Credential.Script(own_hash) =
      own_input.output.address.payment_credential

    // R-3 — exactly one pool UTxO, no other script inputs, on every path.
    let shape_ok = tx_shape_ok(tx.inputs, own_hash)

    // The spent UTxO carries the 1-of-1 NFT its own datum names.
    let authentic =
      quantity_of(own_input.output.value, policy_id, pool_nft_name) == 1

    // V-6 — the datum mirrors the real value on the way in.
    let in_consistent =
      value_matches(
        own_input.output.value,
        policy_id,
        asset_name,
        quote_reserve,
        token_reserve,
        platform_owed,
        creator_owed,
      )

    let branch_ok =
      when redeemer is {
        Buy { min_out } -> validate_buy(d, min_out, own_input, tx)
        Sell { min_out } -> validate_sell(d, min_out, own_input, tx)
        Claim -> validate_claim(d, own_input, tx)
      }

    shape_ok && authentic && in_consistent && branch_ok
  }

  else(_) {
    fail
  }
}

// ── Shared primitives ─────────────────────────────────────────────────────────

/// ██ THE VALUE INVARIANT. ██ Lovelace is a constant; the quote balance is the
/// reserve PLUS both owed counters; the token balance is the reserve exactly.
fn value_matches(
  v: Value,
  policy_id: ByteArray,
  asset_name: ByteArray,
  quote_reserve: Int,
  token_reserve: Int,
  platform_owed: Int,
  creator_owed: Int,
) -> Bool {
  and {
    lovelace_of(v) == pool_floor_v4,
    quantity_of(v, quote_policy_v4, quote_name_v4) == quote_reserve + platform_owed + creator_owed,
    quantity_of(v, policy_id, asset_name) == token_reserve,
  }
}

fn at_script(i: Input, hash: ByteArray) -> Bool {
  when i.output.address.payment_credential is {
    Credential.Script(h) -> h == hash
    Credential.VerificationKey(_) -> False
  }
}

/// R-3 — exactly one pool input and NO other script input. Wallet inputs are
/// unrestricted. This is what makes the existential `Claim` payout checks
/// exact: two pools can never share one payout output.
fn tx_shape_ok(inputs: List<Input>, own_hash: ByteArray) -> Bool {
  let one_pool = list.count(inputs, fn(i) { at_script(i, own_hash) }) == 1
  let confined =
    list.all(
      inputs,
      fn(i) {
        when i.output.address.payment_credential is {
          Credential.Script(h) -> h == own_hash
          Credential.VerificationKey(_) -> True
        }
      },
    )
  one_pool && confined
}

fn pool_nft_kept(own_output: Output, policy_id: ByteArray) -> Bool {
  quantity_of(own_output.value, policy_id, pool_nft_name) == 1
}

/// Exactly one output at the pool's PAYMENT CREDENTIAL (any stake part) …
fn sole_continuation(own_input: Input, tx: Transaction) -> Output {
  expect [own_output] =
    list.filter(
      tx.outputs,
      fn(o) {
        o.address.payment_credential == own_input.output.address.payment_credential
      },
    )
  own_output
}

/// … and it sits at the EXACT address the pool was spent from.
fn continuation_address_exact(own_input: Input, own_output: Output) -> Bool {
  own_output.address == own_input.output.address
}

fn no_ref_script_kept(own_output: Output) -> Bool {
  own_output.reference_script == None
}

/// The pool UTxO holds lovelace, the token, the NFT — and the quote asset iff
/// its total is non-zero (a zero quantity is not an entry). Nothing else.
fn value_shape_ok(v: Value, quote_total: Int) -> Bool {
  let want =
    if quote_total == 0 {
      3
    } else {
      4
    }
  list.length(flatten(v)) == want
}

fn no_policy_mint(tx: Transaction, policy_id: ByteArray) -> Bool {
  dict.to_pairs(tokens(tx.mint, policy_id)) == []
}

/// The platform side of the schedule, pinned at spend time on every branch, so
/// a self-seeded pool at the shared address cannot trade fee-free or redirect
/// the platform's fee. Creator side stays free by design.
fn fee_schedule_ok(
  treasury_pkh: ByteArray,
  creator_fee_bps: Int,
  platform_fee_bps: Int,
  platform_fee_flat: Int,
) -> Bool {
  and {
    treasury_pkh == treasury_pkh_v4,
    platform_fee_bps >= platform_fee_bps_v4,
    platform_fee_flat >= platform_fee_flat_v4,
    creator_fee_bps >= 0,
    creator_fee_bps <= 10_000,
    platform_fee_bps <= 10_000,
  }
}

// ── Buy ───────────────────────────────────────────────────────────────────────

fn validate_buy(
  d: PoolDatum,
  min_out: Int,
  own_input: Input,
  tx: Transaction,
) -> Bool {
  expect PoolDatumV4 {
    policy_id,
    asset_name,
    quote_reserve: old_q,
    token_reserve: old_t,
    platform_owed: old_p,
    creator_owed: old_c,
    treasury_pkh,
    creator_fee_bps,
    platform_fee_bps,
    platform_fee_flat,
    ..
  } = d

  let own_output = sole_continuation(own_input, tx)
  expect InlineDatum(raw) = own_output.datum
  expect new_d: PoolDatum = raw
  expect PoolDatumV4 {
    quote_reserve: new_q,
    token_reserve: new_t,
    platform_owed: new_p,
    creator_owed: new_c,
    ..
  } = new_d

  // R-5 — four fields move, seven are frozen.
  let datum_preserved = with_state(d, new_q, new_t, new_p, new_c) == new_d

  let quote_in = new_q - old_q
  let tokens_out = old_t - new_t

  let out_consistent =
    value_matches(
      own_output.value,
      policy_id,
      asset_name,
      new_q,
      new_t,
      new_p,
      new_c,
    )

  // No minimum trade; a zero or negative "buy" is refused here.
  let quote_in_positive = quote_in > 0

  let correct_tokens_out = tokens_out == quote_buy(old_q, old_t, quote_in)

  // Defence in depth — the quote floors the amount out, so this is shadowed.
  let solvency_ok = new_t >= 1

  let slippage_ok = tokens_out >= min_out

  // Fees are a SURCHARGE on `quote_in`, accrued into the pool.
  let platform_accrued =
    new_p == old_p + platform_fee(quote_in, platform_fee_bps, platform_fee_flat)
  let creator_accrued = new_c == old_c + creator_fee(quote_in, creator_fee_bps)

  and {
    datum_preserved,
    continuation_address_exact(own_input, own_output),
    out_consistent,
    fee_schedule_ok(
      treasury_pkh,
      creator_fee_bps,
      platform_fee_bps,
      platform_fee_flat,
    ),
    quote_in_positive,
    correct_tokens_out,
    solvency_ok,
    slippage_ok,
    platform_accrued,
    creator_accrued,
    pool_nft_kept(own_output, policy_id),
    value_shape_ok(own_output.value, new_q + new_p + new_c),
    no_ref_script_kept(own_output),
    no_policy_mint(tx, policy_id),
  }
}

// ── Sell ──────────────────────────────────────────────────────────────────────

fn validate_sell(
  d: PoolDatum,
  min_out: Int,
  own_input: Input,
  tx: Transaction,
) -> Bool {
  expect PoolDatumV4 {
    policy_id,
    asset_name,
    quote_reserve: old_q,
    token_reserve: old_t,
    platform_owed: old_p,
    creator_owed: old_c,
    treasury_pkh,
    creator_fee_bps,
    platform_fee_bps,
    platform_fee_flat,
    ..
  } = d

  let own_output = sole_continuation(own_input, tx)
  expect InlineDatum(raw) = own_output.datum
  expect new_d: PoolDatum = raw
  expect PoolDatumV4 {
    quote_reserve: new_q,
    token_reserve: new_t,
    platform_owed: new_p,
    creator_owed: new_c,
    ..
  } = new_d

  let datum_preserved = with_state(d, new_q, new_t, new_p, new_c) == new_d

  let tokens_in = new_t - old_t
  let gross = old_q - new_q

  let out_consistent =
    value_matches(
      own_output.value,
      policy_id,
      asset_name,
      new_q,
      new_t,
      new_p,
      new_c,
    )

  let tokens_in_positive = tokens_in > 0
  let correct_gross = gross == quote_sell_gross(old_q, old_t, tokens_in)

  // Only `total_supply_v4` tokens exist, ever.
  let cap_ok = new_t <= total_supply_v4

  // The gross is capped at the real reserve, so this is shadowed; kept.
  let solvency_ok = new_q >= 0

  // Fees are DEDUCTED from the gross and stay in the pool as owed.
  let net = sell_net(gross, creator_fee_bps, platform_fee_bps, platform_fee_flat)

  // A sell must actually pay the seller. A position whose gross cannot cover
  // the flat fee is not sellable — that is the flat fee's nature, and the UI
  // must say so rather than build a transaction the validator refuses.
  let net_positive = net > 0
  let slippage_ok = net >= min_out

  let platform_accrued =
    new_p == old_p + platform_fee(gross, platform_fee_bps, platform_fee_flat)
  let creator_accrued = new_c == old_c + creator_fee(gross, creator_fee_bps)

  and {
    datum_preserved,
    continuation_address_exact(own_input, own_output),
    out_consistent,
    fee_schedule_ok(
      treasury_pkh,
      creator_fee_bps,
      platform_fee_bps,
      platform_fee_flat,
    ),
    tokens_in_positive,
    correct_gross,
    cap_ok,
    solvency_ok,
    net_positive,
    slippage_ok,
    platform_accrued,
    creator_accrued,
    pool_nft_kept(own_output, policy_id),
    value_shape_ok(own_output.value, new_q + new_p + new_c),
    no_ref_script_kept(own_output),
    no_policy_mint(tx, policy_id),
  }
}

// ── Claim ─────────────────────────────────────────────────────────────────────

/// Pay out the owed fees. Reserves are untouched; both counters go to zero.
///   • `burn_share(platform_owed)` → the LUMP-buyback key
///   • the rest of `platform_owed`  → the treasury key
///   • `creator_owed`               → the creator key
/// SIGNED by the creator or the treasury (H-1 fix): the claimer funds the
/// transaction and the payouts' min-UTxO, and the money can only go to the
/// pinned KEY credentials — never to a script address of the same hash.
///
/// ── WHEN THE CREATOR IS THE BUYBACK KEY ──────────────────────────────────────
/// A creator credential equal to `buyback_pkh_v4` routes its fee to the LUMP
/// buyback (the "burn my creator fee" launch option). The payout checks are
/// existential, so two separate "at least X to the buyback" checks would be
/// satisfied by ONE output of max(X, Y) — an underpayment. The two demands are
/// therefore folded into one combined requirement on that single credential.
/// Treasury != creator is pinned at genesis and treasury != buyback is a
/// constant fact, so no other pair of recipients can coincide.
fn validate_claim(d: PoolDatum, own_input: Input, tx: Transaction) -> Bool {
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
  } = d

  let own_output = sole_continuation(own_input, tx)
  expect InlineDatum(raw) = own_output.datum
  expect new_d: PoolDatum = raw

  let datum_zeroed = with_state(d, quote_reserve, token_reserve, 0, 0) == new_d

  // Refuse a no-op claim: it would only ever grief the pool UTxO.
  let something_owed = platform_owed > 0 || creator_owed > 0

  // H-1 — a Claim is authorised by the creator or the treasury, never by a
  // stranger. (The treasury is pinned to the cohort constant by fee_schedule_ok.)
  let claim_signed =
    list.has(tx.extra_signatories, creator_pkh) || list.has(
      tx.extra_signatories,
      treasury_pkh,
    )

  let out_consistent =
    value_matches(
      own_output.value,
      policy_id,
      asset_name,
      quote_reserve,
      token_reserve,
      0,
      0,
    )

  let to_buyback = burn_share(platform_owed)
  let to_treasury = platform_owed - to_buyback
  let creator_is_buyback = creator_pkh == buyback_pkh_v4
  let buyback_required =
    if creator_is_buyback {
      to_buyback + creator_owed
    } else {
      to_buyback
    }

  let buyback_paid =
    buyback_required == 0 || pays_quote_at_least(
      tx.outputs,
      buyback_pkh_v4,
      buyback_required,
    )
  let treasury_paid =
    to_treasury == 0 || pays_quote_at_least(tx.outputs, treasury_pkh, to_treasury)
  let creator_paid =
    creator_is_buyback || creator_owed == 0 || pays_quote_at_least(
      tx.outputs,
      creator_pkh,
      creator_owed,
    )

  and {
    datum_zeroed,
    something_owed,
    claim_signed,
    continuation_address_exact(own_input, own_output),
    out_consistent,
    fee_schedule_ok(
      treasury_pkh,
      creator_fee_bps,
      platform_fee_bps,
      platform_fee_flat,
    ),
    buyback_paid,
    treasury_paid,
    creator_paid,
    pool_nft_kept(own_output, policy_id),
    value_shape_ok(own_output.value, quote_reserve),
    no_ref_script_kept(own_output),
    no_policy_mint(tx, policy_id),
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TESTS — accept/reject per branch. Every number re-derived from params_v4
// (S = 1e9, V = 1e10, lp 30 bps, platform 50 bps + 10,000,000 flat, creator 1%).
// Quote figures are NIGHT BASE UNITS (6 decimals): 100,000,000 = 100 NIGHT.
// Genesis: (0, 1e9, 0, 0). After the canonical 100 NIGHT buy:
// (100,000,000, 990,128,420, 10,500,000, 1,000,000) — 9,871,580 out; pool holds
// 111,500,000 quote.
// ══════════════════════════════════════════════════════════════════════════════

const t_policy: ByteArray =
  #"a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0"

/// "Agent"
const t_name: ByteArray = #"4167656e74"

const t_treasury: ByteArray = treasury_pkh_v4

const t_buyback: ByteArray = buyback_pkh_v4

const t_creator: ByteArray =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

const t_pool: ByteArray =
  #"d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0"

const t_owner: ByteArray =
  #"e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"

const t_other_script: ByteArray =
  #"f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"

const supply: Int = 1_000_000_000

fn dat(q: Int, t: Int, p: Int, c: Int) -> PoolDatum {
  PoolDatumV4 {
    policy_id: t_policy,
    asset_name: t_name,
    quote_reserve: q,
    token_reserve: t,
    platform_owed: p,
    creator_owed: c,
    creator_pkh: t_creator,
    treasury_pkh: t_treasury,
    creator_fee_bps: 100,
    platform_fee_bps: 50,
    platform_fee_flat: 10_000_000,
  }
}

fn dat_full(
  q: Int,
  t: Int,
  p: Int,
  c: Int,
  creator: ByteArray,
  treasury: ByteArray,
  cbps: Int,
  pbps: Int,
  pflat: Int,
) -> PoolDatum {
  PoolDatumV4 {
    policy_id: t_policy,
    asset_name: t_name,
    quote_reserve: q,
    token_reserve: t,
    platform_owed: p,
    creator_owed: c,
    creator_pkh: creator,
    treasury_pkh: treasury,
    creator_fee_bps: cbps,
    platform_fee_bps: pbps,
    platform_fee_flat: pflat,
  }
}

fn p_ref() -> OutputReference {
  oref(#"0101", 0)
}

/// Pool value from a datum's four mutable numbers (lovelace = floor, exactly).
fn pool_value(q: Int, t: Int, p: Int, c: Int) -> Value {
  let base =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(t_policy, t_name, t)
      |> assets.add(t_policy, pool_nft_name, 1)
  if q + p + c == 0 {
    base
  } else {
    base |> assets.add(quote_policy_v4, quote_name_v4, q + p + c)
  }
}

fn p_in(d: PoolDatum, q: Int, t: Int, p: Int, c: Int) -> Input {
  input_of(p_ref(), script_out(t_pool, pool_value(q, t, p, c), d))
}

fn p_out(d: PoolDatum, q: Int, t: Int, p: Int, c: Int) -> Output {
  script_out(t_pool, pool_value(q, t, p, c), d)
}

fn wallet_in(tag: ByteArray, lovelace: Int) -> Input {
  input_of(oref(tag, 0), pk_out(t_owner, lovelace))
}

fn base_tx(ins: List<Input>, outs: List<Output>) -> Transaction {
  Transaction { ..transaction.placeholder, inputs: ins, outputs: outs }
}

/// A transaction carrying one required signer (what a Claim needs).
fn signed_tx(ins: List<Input>, outs: List<Output>, signer: ByteArray) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: ins,
    outputs: outs,
    extra_signatories: [signer],
  }
}

fn spend(d: PoolDatum, r: PoolRedeemer, tx: Transaction) -> Bool {
  lump_pool_v4.spend(Some(d), r, p_ref(), tx)
}

fn quote_out(pkh: ByteArray, qty: Int) -> Output {
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

// ── Genesis buy: 100 NIGHT → 9,871,580 tokens ────────────────────────────────

fn genesis() -> PoolDatum {
  dat(0, supply, 0, 0)
}

fn after_buy() -> PoolDatum {
  dat(100_000_000, 990_128_420, 10_500_000, 1_000_000)
}

fn buy_tx_with(out: Output) -> Transaction {
  base_tx([p_in(genesis(), 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)], [out])
}

fn good_buy_tx() -> Transaction {
  buy_tx_with(p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000))
}

test buy_accepts_canonical_genesis_trade() {
  spend(genesis(), Buy { min_out: 9_871_580 }, good_buy_tx())
}

test buy_accepts_with_lower_min_out() {
  spend(genesis(), Buy { min_out: 1 }, good_buy_tx())
}

test buy_rejects_min_out_above_quote() fail {
  spend(genesis(), Buy { min_out: 9_871_581 }, good_buy_tx())
}

test buy_rejects_wrong_tokens_out() fail {
  let d = dat(100_000_000, 990_128_419, 10_500_000, 1_000_000)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(d, 100_000_000, 990_128_419, 10_500_000, 1_000_000)),
  )
}

test buy_rejects_missing_platform_fee() fail {
  let d = dat(100_000_000, 990_128_420, 0, 1_000_000)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(d, 100_000_000, 990_128_420, 0, 1_000_000)),
  )
}

test buy_rejects_flat_only_platform_fee() fail {
  // 10,000,000 instead of 10,500,000 — the 0.5% bps component is missing
  let d = dat(100_000_000, 990_128_420, 10_000_000, 1_000_000)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(d, 100_000_000, 990_128_420, 10_000_000, 1_000_000)),
  )
}

/// The LUMP cohort's flat fee (10,000 units) on a NIGHT pool is a short fee.
test buy_rejects_lump_scale_flat_fee() fail {
  let d = dat(100_000_000, 990_128_420, 510_000, 1_000_000)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(d, 100_000_000, 990_128_420, 510_000, 1_000_000)),
  )
}

test buy_rejects_missing_creator_fee() fail {
  let d = dat(100_000_000, 990_128_420, 10_500_000, 0)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(d, 100_000_000, 990_128_420, 10_500_000, 0)),
  )
}

test buy_rejects_datum_fee_but_value_short() fail {
  // datum says 111,500,000 quote in the pool; value holds 100,500,000
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(after_buy(), 89_000_000, 990_128_420, 10_500_000, 1_000_000)),
  )
}

test buy_rejects_lovelace_above_floor() fail {
  let v = pool_value(100_000_000, 990_128_420, 10_500_000, 1_000_000) |> assets.add("", "", 1)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(script_out(t_pool, v, after_buy())),
  )
}

test buy_rejects_zero_quote_in() fail {
  let d = dat(0, supply, 10_000_000, 0)
  spend(genesis(), Buy { min_out: 0 }, buy_tx_with(p_out(d, 0, supply, 10_000_000, 0)))
}

test buy_rejects_rewritten_creator() fail {
  let d =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_owner, t_treasury, 100, 50, 10_000_000)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(d, 100_000_000, 990_128_420, 10_500_000, 1_000_000)),
  )
}

test buy_rejects_rewritten_fee_schedule() fail {
  let d =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_creator, t_treasury, 100, 50, 1)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(p_out(d, 100_000_000, 990_128_420, 10_500_000, 1_000_000)),
  )
}

test buy_rejects_foreign_treasury_pool() fail {
  // a self-seeded pool naming another treasury cannot trade here
  let g = dat_full(0, supply, 0, 0, t_creator, t_owner, 100, 50, 10_000_000)
  let n =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_creator, t_owner, 100, 50, 10_000_000)
  let tx =
    base_tx(
      [p_in(g, 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)],
      [p_out(n, 100_000_000, 990_128_420, 10_500_000, 1_000_000)],
    )
  spend(g, Buy { min_out: 0 }, tx)
}

test buy_rejects_self_seeded_pool_with_lower_platform_bps() fail {
  let g = dat_full(0, supply, 0, 0, t_creator, t_treasury, 100, 0, 10_000_000)
  let n =
    dat_full(100_000_000, 990_128_420, 10_000_000, 1_000_000, t_creator, t_treasury, 100, 0, 10_000_000)
  let tx =
    base_tx(
      [p_in(g, 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)],
      [p_out(n, 100_000_000, 990_128_420, 10_000_000, 1_000_000)],
    )
  spend(g, Buy { min_out: 0 }, tx)
}

test buy_rejects_nft_removed() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(t_policy, t_name, 990_128_420)
      |> assets.add(quote_policy_v4, quote_name_v4, 111_500_000)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(script_out(t_pool, v, after_buy())),
  )
}

test buy_rejects_junk_asset_in_continuation() fail {
  let v =
    pool_value(100_000_000, 990_128_420, 10_500_000, 1_000_000)
      |> assets.add(t_other_script, #"6a756e6b", 1)
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(script_out(t_pool, v, after_buy())),
  )
}

/// $LUMP (the other cohort's quote) in the continuation is a junk asset here.
test buy_rejects_lump_paid_as_quote() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(t_policy, t_name, 990_128_420)
      |> assets.add(t_policy, pool_nft_name, 1)
      |> assets.add(
          #"73797786382c0832b5787a5b306f5308488f14571b7061f79396ad2c",
          #"4c756d70",
          111_500_000,
        )
  spend(
    genesis(),
    Buy { min_out: 0 },
    buy_tx_with(script_out(t_pool, v, after_buy())),
  )
}

test buy_rejects_staked_continuation() fail {
  let out =
    script_out_staked(
      t_pool,
      t_owner,
      pool_value(100_000_000, 990_128_420, 10_500_000, 1_000_000),
      after_buy(),
    )
  spend(genesis(), Buy { min_out: 0 }, buy_tx_with(out))
}

test buy_rejects_two_continuations() fail {
  let tx =
    base_tx(
      [p_in(genesis(), 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)],
      [
        p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000),
        p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000),
      ],
    )
  spend(genesis(), Buy { min_out: 0 }, tx)
}

test buy_rejects_second_script_input() fail {
  let foreign =
    input_of(
      oref(#"0303", 0),
      script_out(t_other_script, assets.from_lovelace(2_000_000), 0),
    )
  let tx =
    base_tx(
      [p_in(genesis(), 0, supply, 0, 0), foreign, wallet_in(#"0202", 20_000_000)],
      [p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000)],
    )
  spend(genesis(), Buy { min_out: 0 }, tx)
}

test buy_rejects_two_pools_in_one_tx() fail {
  let second =
    input_of(oref(#"0404", 0), script_out(t_pool, pool_value(0, supply, 0, 0), genesis()))
  let tx =
    base_tx(
      [p_in(genesis(), 0, supply, 0, 0), second, wallet_in(#"0202", 20_000_000)],
      [p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000)],
    )
  spend(genesis(), Buy { min_out: 0 }, tx)
}

test buy_rejects_mint_under_pool_policy() fail {
  let tx =
    Transaction { ..good_buy_tx(), mint: assets.from_asset(t_policy, t_name, 1) }
  spend(genesis(), Buy { min_out: 0 }, tx)
}

test buy_rejects_inconsistent_input_datum() fail {
  // datum claims 5 quote reserve, the UTxO holds none
  let lying = dat(5, supply, 0, 0)
  let tx =
    base_tx(
      [p_in(lying, 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)],
      [p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000)],
    )
  spend(lying, Buy { min_out: 0 }, tx)
}

test buy_rejects_decoy_without_nft() fail {
  let v = assets.from_lovelace(pool_floor_v4) |> assets.add(t_policy, t_name, supply)
  let tx =
    base_tx(
      [
        input_of(p_ref(), script_out(t_pool, v, genesis())),
        wallet_in(#"0202", 20_000_000),
      ],
      [p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000)],
    )
  spend(genesis(), Buy { min_out: 0 }, tx)
}

/// A second buy on a pool that already carries owed fees accrues on top.
/// From (100,000,000, 990,128,420, 10,500,000, 1,000,000), buy 50 NIGHT: net
/// 49,850,000 → ⌊49,850,000 × 990,128,420 / 10,149,850,000⌋ = 4,862,919;
/// fees 10,250,000 / 500,000.
test buy_accepts_second_trade_accumulating_fees() {
  let n = dat(150_000_000, 985_265_501, 20_750_000, 1_500_000)
  let tx =
    base_tx(
      [
        p_in(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000),
        wallet_in(#"0202", 20_000_000),
      ],
      [p_out(n, 150_000_000, 985_265_501, 20_750_000, 1_500_000)],
    )
  spend(after_buy(), Buy { min_out: 4_862_919 }, tx)
}

// ── Sell: 9,871,580 tokens back → gross 99,406,790 ────────────────────────────
// creator_fee(99,406,790, 100) = 994,067; platform 99,406,790 × 50 / 10,000 +
// 10,000,000 = 10,497,033; net = 87,915,690. Continuation: q 593,210, t 1e9,
// owed 20,997,033 / 1,994,067 → 23,584,310 quote held.

fn after_sell() -> PoolDatum {
  dat(593_210, supply, 20_997_033, 1_994_067)
}

fn sell_tx_with(out: Output) -> Transaction {
  base_tx(
    [
      p_in(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000),
      wallet_in(#"0202", 20_000_000),
    ],
    [out],
  )
}

fn good_sell_tx() -> Transaction {
  sell_tx_with(p_out(after_sell(), 593_210, supply, 20_997_033, 1_994_067))
}

test sell_accepts_canonical_roundtrip() {
  spend(after_buy(), Sell { min_out: 87_915_690 }, good_sell_tx())
}

test sell_rejects_min_out_above_net() fail {
  spend(after_buy(), Sell { min_out: 87_915_691 }, good_sell_tx())
}

test sell_rejects_wrong_gross() fail {
  let d = dat(593_209, supply, 20_997_033, 1_994_067)
  spend(
    after_buy(),
    Sell { min_out: 0 },
    sell_tx_with(p_out(d, 593_209, supply, 20_997_033, 1_994_067)),
  )
}

test sell_rejects_unaccrued_fees() fail {
  let d = dat(593_210, supply, 10_500_000, 1_000_000)
  spend(
    after_buy(),
    Sell { min_out: 0 },
    sell_tx_with(p_out(d, 593_210, supply, 10_500_000, 1_000_000)),
  )
}

test sell_rejects_over_supply() fail {
  let d = dat(593_210, supply + 1, 20_997_033, 1_994_067)
  spend(
    after_buy(),
    Sell { min_out: 0 },
    sell_tx_with(p_out(d, 593_210, supply + 1, 20_997_033, 1_994_067)),
  )
}

test sell_rejects_zero_tokens_in() fail {
  spend(
    after_buy(),
    Sell { min_out: 0 },
    sell_tx_with(p_out(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000)),
  )
}

/// A dust sell whose gross is below the flat fee is refused (net ≤ 0).
/// Sell 500,000 tokens from (100,000,000, 990,128,420): net 498,500 → gross
/// ⌊498,500 × 10,100,000,000 / 990,626,920⌋ = 5,082,488; fees 50,824 +
/// 10,254,124 → net < 0.
test sell_rejects_position_below_flat_fee() fail {
  let d = dat(94_917_512, 990_628_420, 20_525_412, 1_050_824)
  spend(
    after_buy(),
    Sell { min_out: -20_000_000 },
    sell_tx_with(p_out(d, 94_917_512, 990_628_420, 20_525_412, 1_050_824)),
  )
}

test sell_rejects_lovelace_siphon() fail {
  let v =
    assets.from_lovelace(pool_floor_v4 - 1)
      |> assets.add(t_policy, t_name, supply)
      |> assets.add(t_policy, pool_nft_name, 1)
      |> assets.add(quote_policy_v4, quote_name_v4, 23_584_310)
  spend(
    after_buy(),
    Sell { min_out: 0 },
    sell_tx_with(script_out(t_pool, v, after_sell())),
  )
}

// ── Claim: platform 10,500,000 → buyback 5,250,000 + treasury 5,250,000; ─────
// ── creator 1,000,000. Signed by the creator unless a test says otherwise. ────

fn claimed() -> PoolDatum {
  dat(100_000_000, 990_128_420, 0, 0)
}

fn claim_tx_signed(outs: List<Output>, signer: ByteArray) -> Transaction {
  signed_tx(
    [
      p_in(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000),
      wallet_in(#"0202", 20_000_000),
    ],
    outs,
    signer,
  )
}

fn claim_tx_with(outs: List<Output>) -> Transaction {
  claim_tx_signed(outs, t_creator)
}

fn good_claim_outputs() -> List<Output> {
  [
    p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
    quote_out(t_buyback, 5_250_000),
    quote_out(t_treasury, 5_250_000),
    quote_out(t_creator, 1_000_000),
  ]
}

fn good_claim_tx() -> Transaction {
  claim_tx_with(good_claim_outputs())
}

test claim_accepts_canonical_signed_by_creator() {
  spend(after_buy(), Claim, good_claim_tx())
}

test claim_accepts_signed_by_treasury() {
  spend(after_buy(), Claim, claim_tx_signed(good_claim_outputs(), t_treasury))
}

/// H-1: no signature at all — the LUMP cohort accepted this; here it is refused.
test claim_rejects_unsigned() fail {
  let tx =
    base_tx(
      [
        p_in(after_buy(), 100_000_000, 990_128_420, 10_500_000, 1_000_000),
        wallet_in(#"0202", 20_000_000),
      ],
      good_claim_outputs(),
    )
  spend(after_buy(), Claim, tx)
}

/// H-1: signed by a stranger (the wallet funding the tx) — refused.
test claim_rejects_signed_by_stranger() fail {
  spend(after_buy(), Claim, claim_tx_signed(good_claim_outputs(), t_owner))
}

/// H-1: the buyback key's hash is not a signer — its payout is a right, not an authority.
test claim_rejects_signed_by_buyback_key_when_creator_is_not_it() fail {
  spend(after_buy(), Claim, claim_tx_signed(good_claim_outputs(), t_buyback))
}

test claim_rejects_short_buyback() fail {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_249_999),
        quote_out(t_treasury, 5_250_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

test claim_rejects_missing_buyback() fail {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_treasury, 10_500_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

test claim_rejects_short_treasury() fail {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_249_999),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

test claim_rejects_missing_creator_payout() fail {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

test claim_rejects_reserve_change() fail {
  let d = dat(99_000_000, 990_128_420, 0, 0)
  let tx =
    claim_tx_with(
      [
        p_out(d, 99_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 6_250_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

test claim_rejects_counters_not_zeroed() fail {
  let d = dat(100_000_000, 990_128_420, 10_500_000, 0)
  let tx =
    claim_tx_with(
      [
        p_out(d, 100_000_000, 990_128_420, 10_500_000, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

test claim_rejects_nothing_owed() fail {
  let tx =
    signed_tx(
      [p_in(claimed(), 100_000_000, 990_128_420, 0, 0), wallet_in(#"0202", 20_000_000)],
      [p_out(claimed(), 100_000_000, 990_128_420, 0, 0)],
      t_creator,
    )
  spend(claimed(), Claim, tx)
}

test claim_rejects_payout_to_wrong_key() fail {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_owner, 5_250_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

/// H-1 CLOSED: treasury and creator paid to SCRIPT-credential addresses of the
/// same hash (unspendable by anyone) — accepted by the LUMP cohort, refused here.
test claim_rejects_treasury_and_creator_paid_to_script_credential() fail {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out_script(t_treasury, 5_250_000),
        quote_out_script(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

/// H-1 CLOSED: the buyback share paid to a script credential of the buyback hash.
test claim_rejects_buyback_paid_to_script_credential() fail {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out_script(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

/// Odd platform_owed: the treasury gets the extra unit.
test claim_accepts_odd_split() {
  let g = dat(100_000_000, 990_128_420, 10_500_001, 0)
  let tx =
    signed_tx(
      [p_in(g, 100_000_000, 990_128_420, 10_500_001, 0), wallet_in(#"0202", 20_000_000)],
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_001),
      ],
      t_treasury,
    )
  spend(g, Claim, tx)
}

test claim_rejects_odd_split_short_treasury() fail {
  let g = dat(100_000_000, 990_128_420, 10_500_001, 0)
  let tx =
    signed_tx(
      [p_in(g, 100_000_000, 990_128_420, 10_500_001, 0), wallet_in(#"0202", 20_000_000)],
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
      ],
      t_treasury,
    )
  spend(g, Claim, tx)
}

/// Creator IS the buyback key (the "burn my creator fee" case): ONE output to
/// the buyback key must carry buyback share + creator fee combined.
test claim_accepts_creator_as_buyback_combined_output() {
  let g =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_buyback, t_treasury, 100, 50, 10_000_000)
  let z = dat_full(100_000_000, 990_128_420, 0, 0, t_buyback, t_treasury, 100, 50, 10_000_000)
  let tx =
    signed_tx(
      [p_in(g, 100_000_000, 990_128_420, 10_500_000, 1_000_000), wallet_in(#"0202", 20_000_000)],
      [
        p_out(z, 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 6_250_000),
        quote_out(t_treasury, 5_250_000),
      ],
      t_treasury,
    )
  spend(g, Claim, tx)
}

/// … and since the creator IS the buyback key, that key may sign the claim.
test claim_accepts_creator_as_buyback_signed_by_buyback_key() {
  let g =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_buyback, t_treasury, 100, 50, 10_000_000)
  let z = dat_full(100_000_000, 990_128_420, 0, 0, t_buyback, t_treasury, 100, 50, 10_000_000)
  let tx =
    signed_tx(
      [p_in(g, 100_000_000, 990_128_420, 10_500_000, 1_000_000), wallet_in(#"0202", 20_000_000)],
      [
        p_out(z, 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 6_250_000),
        quote_out(t_treasury, 5_250_000),
      ],
      t_buyback,
    )
  spend(g, Claim, tx)
}

test claim_rejects_creator_as_buyback_paid_only_buyback_share() fail {
  let g =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_buyback, t_treasury, 100, 50, 10_000_000)
  let z = dat_full(100_000_000, 990_128_420, 0, 0, t_buyback, t_treasury, 100, 50, 10_000_000)
  let tx =
    signed_tx(
      [p_in(g, 100_000_000, 990_128_420, 10_500_000, 1_000_000), wallet_in(#"0202", 20_000_000)],
      [
        p_out(z, 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
      ],
      t_treasury,
    )
  spend(g, Claim, tx)
}

// ══════════════════════════════════════════════════════════════════════════════
// Binding tests carried over from the 2026-09-12 adversarial review of the LUMP
// cohort. The
// `fail` tests pin guards the mutation pass found load-bearing but untested;
// the accepting `poc_*` tests DOCUMENT behaviour this cohort still accepts
// (I-1, L-1, M-2, I-2). H-1 is CLOSED above.
// ══════════════════════════════════════════════════════════════════════════════

fn quote_out_key_staked(h: ByteArray, stake: ByteArray, qty: Int) -> Output {
  Output {
    address: address.Address {
      payment_credential: Credential.VerificationKey(h),
      stake_credential: Some(address.Inline(Credential.VerificationKey(stake))),
    },
    value: assets.from_lovelace(1_200_000)
      |> assets.add(quote_policy_v4, quote_name_v4, qty),
    datum: NoDatum,
    reference_script: None,
  }
}

/// I-1: the payout may carry ANY stake credential (here the claimer's) — the
/// payment key is what is checked, and it is still spendable by the treasury.
test poc_claim_accepts_treasury_payout_delegated_to_claimer_stake_key() {
  let tx =
    claim_tx_with(
      [
        p_out(claimed(), 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out_key_staked(t_treasury, t_owner, 5_250_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

/// L-1: quote_in = 1 → net 0 → 0 tokens out; trader pays 10,000,001 for nothing.
test poc_buy_accepts_quote_in_1_zero_tokens_out() {
  let n = dat(1, supply, 10_000_000, 0)
  spend(genesis(), Buy { min_out: 0 }, buy_tx_with(p_out(n, 1, supply, 10_000_000, 0)))
}

/// M-2: a self-seeded pool with creator_fee_bps = 10,000 trades on the Buy side …
test poc_self_seeded_pool_creator_bps_10000_buy_accepted() {
  let g = dat_full(0, supply, 0, 0, t_owner, t_treasury, 10_000, 50, 10_000_000)
  let n =
    dat_full(
      100_000_000,
      990_128_420,
      10_500_000,
      100_000_000,
      t_owner,
      t_treasury,
      10_000,
      50,
      10_000_000,
    )
  let tx =
    base_tx(
      [p_in(g, 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)],
      [p_out(n, 100_000_000, 990_128_420, 10_500_000, 100_000_000)],
    )
  spend(g, Buy { min_out: 0 }, tx)
}

/// … and NO sell can ever clear net_positive on it (net = gross − gross − platform).
test poc_self_seeded_pool_creator_bps_10000_sell_always_refused() fail {
  let g =
    dat_full(
      100_000_000,
      990_128_420,
      10_500_000,
      100_000_000,
      t_owner,
      t_treasury,
      10_000,
      50,
      10_000_000,
    )
  let n =
    dat_full(593_210, supply, 20_997_033, 199_406_790, t_owner, t_treasury, 10_000, 50, 10_000_000)
  let tx =
    base_tx(
      [
        p_in(g, 100_000_000, 990_128_420, 10_500_000, 100_000_000),
        wallet_in(#"0202", 20_000_000),
      ],
      [p_out(n, 593_210, supply, 20_997_033, 199_406_790)],
    )
  spend(g, Sell { min_out: -1_000_000_000 }, tx)
}

/// I-2: self-seeded pool with creator == treasury: one treasury output satisfies
/// both existential checks; the creator share goes to the claimer. Only the
/// treasury itself can sign such a claim on this cohort, so it can only skim
/// from its own self-seeded pool.
test poc_self_seeded_creator_equals_treasury_claim_skims_creator_share() {
  let g =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_treasury, t_treasury, 100, 50, 10_000_000)
  let z = dat_full(100_000_000, 990_128_420, 0, 0, t_treasury, t_treasury, 100, 50, 10_000_000)
  let tx =
    signed_tx(
      [p_in(g, 100_000_000, 990_128_420, 10_500_000, 1_000_000), wallet_in(#"0202", 20_000_000)],
      [
        p_out(z, 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
        quote_out(t_owner, 1_000_000),
      ],
      t_treasury,
    )
  spend(g, Claim, tx)
}

/// A creator equal to the pool hash is payable at a KEY address of that hash
/// (a script address never matches now); the treasury must still sign.
test poc_self_seeded_creator_is_pool_hash_paid_via_key_credential() {
  let g =
    dat_full(100_000_000, 990_128_420, 10_500_000, 1_000_000, t_pool, t_treasury, 100, 50, 10_000_000)
  let z = dat_full(100_000_000, 990_128_420, 0, 0, t_pool, t_treasury, 100, 50, 10_000_000)
  let tx =
    signed_tx(
      [p_in(g, 100_000_000, 990_128_420, 10_500_000, 1_000_000), wallet_in(#"0202", 20_000_000)],
      [
        p_out(z, 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
        quote_out(t_pool, 1_000_000),
      ],
      t_treasury,
    )
  spend(g, Claim, tx)
}

/// Test-gap probe: a Sell that rewrites the creator in the continuation datum
/// (everything else canonical) MUST be refused — datum_preserved is the only guard.
test poc_sell_rejects_rewritten_creator() fail {
  let n =
    dat_full(593_210, supply, 20_997_033, 1_994_067, t_owner, t_treasury, 100, 50, 10_000_000)
  spend(after_buy(), Sell { min_out: 0 }, sell_tx_with(p_out(n, 593_210, supply, 20_997_033, 1_994_067)))
}

/// Test-gap probe: a Claim that rewrites the creator in the continuation datum
/// (value canonical) MUST be refused — datum_zeroed is the only guard.
test poc_claim_rejects_rewritten_creator() fail {
  let z = dat_full(100_000_000, 990_128_420, 0, 0, t_owner, t_treasury, 100, 50, 10_000_000)
  let tx =
    claim_tx_with(
      [
        p_out(z, 100_000_000, 990_128_420, 0, 0),
        quote_out(t_buyback, 5_250_000),
        quote_out(t_treasury, 5_250_000),
        quote_out(t_creator, 1_000_000),
      ],
    )
  spend(after_buy(), Claim, tx)
}

/// Test-gap probe: Sell continuation at a staked address MUST be refused.
test poc_sell_rejects_staked_continuation() fail {
  let out =
    script_out_staked(t_pool, t_owner, pool_value(593_210, supply, 20_997_033, 1_994_067), after_sell())
  spend(after_buy(), Sell { min_out: 0 }, sell_tx_with(out))
}

/// Test-gap probe: NFT swapped for a junk asset (entry count unchanged) MUST be refused.
test poc_buy_rejects_nft_swapped_for_junk() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(t_policy, t_name, 990_128_420)
      |> assets.add(t_other_script, #"6a756e6b", 1)
      |> assets.add(quote_policy_v4, quote_name_v4, 111_500_000)
  spend(genesis(), Buy { min_out: 0 }, buy_tx_with(script_out(t_pool, v, after_buy())))
}

/// Test-gap probe (P08): datum says token_reserve = 990,128,420 but the continuation
/// holds one token fewer (trader takes 1 extra). ONLY value_matches' token line
/// refuses this. Must be refused.
test poc_buy_rejects_continuation_token_short_of_datum() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(t_policy, t_name, 990_128_419)
      |> assets.add(t_policy, pool_nft_name, 1)
      |> assets.add(quote_policy_v4, quote_name_v4, 111_500_000)
  spend(genesis(), Buy { min_out: 0 }, buy_tx_with(script_out(t_pool, v, after_buy())))
}

/// Test-gap probe (P03): input datum lies (q = 5, UTxO holds 0) and the continuation
/// is computed FROM the lie, so only in_consistent refuses it. Must be refused.
/// From (5, S): buy 100,000,000 → net 99,700,000 → ⌊99,700,000e9 / 10,099,700,005⌋ = 9,871,580.
test poc_buy_rejects_lying_input_datum_with_consistent_continuation() fail {
  let lying = dat(5, supply, 0, 0)
  let n = dat(100_000_005, supply - 9_871_580, 10_500_000, 1_000_000)
  let tx =
    base_tx(
      [p_in(lying, 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)],
      [p_out(n, 100_000_005, supply - 9_871_580, 10_500_000, 1_000_000)],
    )
  spend(lying, Buy { min_out: 0 }, tx)
}

/// Test-gap probe (P17): a self-seeded pool whose datum carries platform_fee_flat = 0
/// must not trade (fee_schedule_ok pins flat >= v4). Must be refused.
test poc_buy_rejects_self_seeded_pool_with_zero_flat_fee() fail {
  let g = dat_full(0, supply, 0, 0, t_creator, t_treasury, 100, 50, 0)
  let n = dat_full(100_000_000, 990_128_420, 500_000, 1_000_000, t_creator, t_treasury, 100, 50, 0)
  let tx =
    base_tx(
      [p_in(g, 0, supply, 0, 0), wallet_in(#"0202", 20_000_000)],
      [p_out(n, 100_000_000, 990_128_420, 500_000, 1_000_000)],
    )
  spend(g, Buy { min_out: 0 }, tx)
}

/// Test-gap probe (P47/P48): Sell continuation without the NFT (junk in its slot)
/// must be refused.
test poc_sell_rejects_nft_swapped_for_junk() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(t_policy, t_name, supply)
      |> assets.add(t_other_script, #"6a756e6b", 1)
      |> assets.add(quote_policy_v4, quote_name_v4, 23_584_310)
  spend(after_buy(), Sell { min_out: 0 }, sell_tx_with(script_out(t_pool, v, after_sell())))
}

/// Test-gap probe (P43 alone): Sell that accrues the creator fee but not the platform fee.
test poc_sell_rejects_missing_platform_fee_only() fail {
  let d = dat(593_210, supply, 10_500_000, 1_994_067)
  spend(after_buy(), Sell { min_out: 0 }, sell_tx_with(p_out(d, 593_210, supply, 10_500_000, 1_994_067)))
}

/// Test-gap probe (P44 alone): Sell that accrues the platform fee but not the creator fee.
test poc_sell_rejects_missing_creator_fee_only() fail {
  let d = dat(593_210, supply, 20_997_033, 1_000_000)
  spend(after_buy(), Sell { min_out: 0 }, sell_tx_with(p_out(d, 593_210, supply, 20_997_033, 1_000_000)))
}
