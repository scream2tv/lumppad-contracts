use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Credential}
use cardano/assets.{lovelace_of, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use lumpfun/fees_v4.{creator_fee, platform_fee}
use lumpfun/math_v4.{quote_buy}
use lumpfun/params_v4.{
  buyback_pkh_v4, creator_fee_bps_v4, platform_fee_bps_v4,
  platform_fee_flat_v4, pool_floor_v4, quote_name_v4, quote_policy_v4,
  total_supply_v4, treasury_pkh_v4,
}
use lumpfun/pool_types.{PoolDatum, PoolDatumV4, pool_nft_name}
use lumpfun/types.{Launch, MintRedeemer}
use lumpfun/test_helpers.{input_of, pk_out, script_out, script_out_staked}

// ══════════════════════════════════════════════════════════════════════════════
// LumpFun v4 one-shot minting policy — Launch-only, DONG-quoted cohort
//
// Byte-for-byte the LUMP cohort's policy (`cardano-v4`) compiled against
// this cohort's params: the quote asset is $DONG and the "burn" recipient a
// creator may pick is the LUMP-buyback KEY. The seed UTxO must be consumed, so
// the policy id is globally unique and the launch happens exactly once; there
// is NO burn path, so supply is `total_supply_v4` for life and the pool NFT is
// 1-of-1 for life. `pool_seeded` pins the genesis pool: 100% of supply (less an
// optional genesis buy priced like any other buy), the exact lovelace floor,
// the cohort fee schedule, the cohort treasury, and the quote balance equal to
// reserve + owed fees, all derived from the OUTPUT's value.
//
// THE LAUNCHER SEEDS NO QUOTE ASSET. A plain launch has `quote_reserve = 0`,
// no quote entry in the value, and both owed counters at 0. THERE IS NO
// CREATOR ALLOCATION: every token outside the pool was bought on the curve.
//
// ── THE PIN IS ONLY AS STRONG AS PARAMETER APPLICATION ───────────────────────
// `pool_script_hash` is a PARAMETER. `hashes.expected` carries the canonical
// pool hash; the off-chain recompute of (seed, canonical_pool_hash) → policy id
// must run with NO fallback to asset matching.
// ══════════════════════════════════════════════════════════════════════════════

validator lump_mint_v4(
  one_shot_utxo: OutputReference,
  pool_script_hash: ByteArray,
) {
  mint(redeemer: MintRedeemer, policy_id: ByteArray, tx: Transaction) {
    let Launch = redeemer

    let one_shot_ok =
      list.any(tx.inputs, fn(i) { i.output_reference == one_shot_utxo })

    // EXACTLY two assets under this policy: the token at `total_supply_v4` and
    // the 1-of-1 pool NFT.
    let supply_ok =
      when dict.to_pairs(tokens(tx.mint, policy_id)) is {
        [Pair(n1, q1), Pair(n2, q2)] ->
          if n1 == pool_nft_name {
            q1 == 1 && q2 == total_supply_v4 && pool_seeded(
              tx.outputs,
              policy_id,
              n2,
              pool_script_hash,
            )
          } else if n2 == pool_nft_name {
            q2 == 1 && q1 == total_supply_v4 && pool_seeded(
              tx.outputs,
              policy_id,
              n1,
              pool_script_hash,
            )
          } else {
            False
          }
        _ -> False
      }

    one_shot_ok && supply_ok
  }

  else(_) {
    fail
  }
}

fn pool_seeded(
  outputs: List<Output>,
  policy_id: ByteArray,
  token_name: ByteArray,
  pool_script_hash: ByteArray,
) -> Bool {
  let carriers =
    list.filter(
      outputs,
      fn(o) { quantity_of(o.value, policy_id, pool_nft_name) == 1 },
    )
  when carriers is {
    [pool] -> {
      let payment_ok =
        when pool.address.payment_credential is {
          Credential.Script(h) -> h == pool_script_hash
          Credential.VerificationKey(_) -> False
        }
      let bare_address_ok = pool.address.stake_credential == None
      // The floor, exactly. Lovelace is never part of the price.
      let floor_ok = lovelace_of(pool.value) == pool_floor_v4
      let no_ref_script_ok = pool.reference_script == None

      // Everything derived from the OUTPUT, nothing declared.
      let quote_total = quantity_of(pool.value, quote_policy_v4, quote_name_v4)
      let tokens_out =
        total_supply_v4 - quantity_of(pool.value, policy_id, token_name)
      let entries =
        if quote_total == 0 {
          3
        } else {
          4
        }
      let value_ok =
        and {
          tokens_out >= 0,
          quote_total >= 0,
          list.length(assets.flatten(pool.value)) == entries,
        }

      let datum_ok =
        when pool.datum is {
          InlineDatum(raw) -> {
            expect d: PoolDatum = raw
            // Every field, no `..` — adding a field breaks this at compile time.
            expect PoolDatumV4 {
              policy_id: d_policy,
              asset_name: d_name,
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
            and {
              d_policy == policy_id,
              d_name == token_name,
              // Reserves pinned to the output.
              token_reserve == total_supply_v4 - tokens_out,
              quote_reserve >= 0,
              quote_total == quote_reserve + platform_owed + creator_owed,
              // The genesis buy (or its absence), priced like any other buy.
              genesis_trade_ok(
                quote_reserve,
                tokens_out,
                platform_owed,
                creator_owed,
              ),
              // Cohort fee schedule + treasury, pinned.
              creator_fee_bps == creator_fee_bps_v4,
              platform_fee_bps == platform_fee_bps_v4,
              platform_fee_flat == platform_fee_flat_v4,
              treasury_pkh == treasury_pkh_v4,
              builtin.length_of_bytearray(creator_pkh) == 28,
              builtin.length_of_bytearray(treasury_pkh) == 28,
              // Distinct recipients, and neither may be the pool script itself
              // (see fees_v4.pays_quote_at_least). The creator MAY be the buyback
              // key — that routes the creator fee to the LUMP buyback.
              creator_pkh != treasury_pkh,
              creator_pkh != pool_script_hash,
              treasury_pkh != pool_script_hash,
            }
          }
          _ -> False
        }

      and {
        payment_ok,
        bare_address_ok,
        floor_ok,
        no_ref_script_ok,
        value_ok,
        datum_ok,
      }
    }
    _ -> False
  }
}

/// `quote_reserve == 0` is a plain launch: nothing sold, nothing owed. Otherwise
/// the genesis state must be exactly the result of a `Buy` of `quote_reserve`
/// at (0, total_supply_v4): the quote recomputed, both fees accrued.
fn genesis_trade_ok(
  quote_reserve: Int,
  tokens_out: Int,
  platform_owed: Int,
  creator_owed: Int,
) -> Bool {
  if quote_reserve == 0 {
    tokens_out == 0 && platform_owed == 0 && creator_owed == 0
  } else {
    and {
      tokens_out == quote_buy(0, total_supply_v4, quote_reserve),
      platform_owed == platform_fee(
        quote_reserve,
        platform_fee_bps_v4,
        platform_fee_flat_v4,
      ),
      creator_owed == creator_fee(quote_reserve, creator_fee_bps_v4),
    }
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// TESTS — lump_mint_v4 (S = 1e9; genesis buy 25,000 DONG → 9,871,580 tokens,
// owed 2,625 / 250, pool holds 27,875 quote and 990,128,420 tokens)
// ══════════════════════════════════════════════════════════════════════════════

const mp_policy: ByteArray = #"b1b1b1b1"

/// "Agent"
const mp_name: ByteArray = #"4167656e74"

const mp_pool: ByteArray =
  #"d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"

const mp_creator: ByteArray =
  #"c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"

const mp_treasury: ByteArray = treasury_pkh_v4

const mp_foreign_treasury: ByteArray =
  #"7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a"

const supply: Int = 1_000_000_000

fn mp_seed() -> OutputReference {
  OutputReference { transaction_id: #"aaaa", output_index: 0 }
}

fn seed_input(ref: OutputReference) -> Input {
  input_of(ref, pk_out(#"11111111", 2_000_000))
}

fn mint_call(seed: OutputReference, r: MintRedeemer, tx: Transaction) -> Bool {
  lump_mint_v4.mint(seed, mp_pool, r, mp_policy, tx)
}

fn launch_mint(token_qty: Int, nft_qty: Int) -> assets.Value {
  assets.from_asset(mp_policy, mp_name, token_qty)
    |> assets.add(mp_policy, pool_nft_name, nft_qty)
}

fn gd(
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
    policy_id: mp_policy,
    asset_name: mp_name,
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

fn genesis_datum() -> PoolDatum {
  gd(
    0,
    supply,
    0,
    0,
    mp_creator,
    mp_treasury,
    creator_fee_bps_v4,
    platform_fee_bps_v4,
    platform_fee_flat_v4,
  )
}

fn pool_out(
  lovelace: Int,
  token_qty: Int,
  nft_qty: Int,
  quote_qty: Int,
  d: PoolDatum,
) -> Output {
  let base =
    assets.from_lovelace(lovelace)
      |> assets.add(mp_policy, mp_name, token_qty)
      |> assets.add(mp_policy, pool_nft_name, nft_qty)
  let v =
    if quote_qty == 0 {
      base
    } else {
      base |> assets.add(quote_policy_v4, quote_name_v4, quote_qty)
    }
  script_out(mp_pool, v, d)
}

fn good_pool() -> Output {
  pool_out(pool_floor_v4, supply, 1, 0, genesis_datum())
}

fn mint_tx_out(
  seed: OutputReference,
  minted: assets.Value,
  outs: List<Output>,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [seed_input(seed)],
    mint: minted,
    outputs: outs,
  }
}

fn mint_tx(seed: OutputReference, minted: assets.Value) -> Transaction {
  mint_tx_out(seed, minted, [good_pool()])
}

fn launch_with_pool(out: Output) -> Bool {
  mint_call(mp_seed(), Launch, mint_tx_out(mp_seed(), launch_mint(supply, 1), [out]))
}

fn launch_with_datum(d: PoolDatum) -> Bool {
  launch_with_pool(pool_out(pool_floor_v4, supply, 1, 0, d))
}

// ── Happy paths ───────────────────────────────────────────────────────────────

test mint_accepts_canonical_v4_launch() {
  mint_call(mp_seed(), Launch, mint_tx(mp_seed(), launch_mint(supply, 1)))
}

/// Genesis buy of 25,000 DONG: 9,871,580 tokens out, 2,625 + 250 owed,
/// pool holds 27,875 quote and 990,128,420 tokens.
test mint_accepts_genesis_buy() {
  let d =
    gd(25_000, 990_128_420, 2_625, 250, mp_creator, mp_treasury, 100, 50, 2_500)
  launch_with_pool(pool_out(pool_floor_v4, 990_128_420, 1, 27_875, d))
}

/// The "burn my creator fee" case: creator credential = the LUMP-buyback key.
test mint_accepts_creator_as_buyback_key() {
  launch_with_datum(
    gd(
      0,
      supply,
      0,
      0,
      buyback_pkh_v4,
      mp_treasury,
      creator_fee_bps_v4,
      platform_fee_bps_v4,
      platform_fee_flat_v4,
    ),
  )
}

// ── Rejects: one property at a time ──────────────────────────────────────────

test mint_rejects_when_seed_not_spent() fail {
  let other = OutputReference { transaction_id: #"bbbb", output_index: 0 }
  mint_call(mp_seed(), Launch, mint_tx(other, launch_mint(supply, 1)))
}

test mint_rejects_wrong_supply() fail {
  mint_call(
    mp_seed(),
    Launch,
    mint_tx_out(
      mp_seed(),
      launch_mint(supply + 1, 1),
      [pool_out(pool_floor_v4, supply + 1, 1, 0, genesis_datum())],
    ),
  )
}

test mint_rejects_two_nfts() fail {
  mint_call(mp_seed(), Launch, mint_tx(mp_seed(), launch_mint(supply, 2)))
}

test mint_rejects_third_asset() fail {
  let m = launch_mint(supply, 1) |> assets.add(mp_policy, #"6578747261", 1)
  mint_call(mp_seed(), Launch, mint_tx(mp_seed(), m))
}

test mint_rejects_supply_kept_by_launcher() fail {
  // 999,999,999 seated, 1 kept, datum claims a plain launch
  launch_with_pool(pool_out(pool_floor_v4, supply - 1, 1, 0, genesis_datum()))
}

test mint_rejects_wrong_pool_script() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(mp_policy, mp_name, supply)
      |> assets.add(mp_policy, pool_nft_name, 1)
  launch_with_pool(
    script_out(
      #"e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1",
      v,
      genesis_datum(),
    ),
  )
}

test mint_rejects_staked_pool_address() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(mp_policy, mp_name, supply)
      |> assets.add(mp_policy, pool_nft_name, 1)
  launch_with_pool(
    script_out_staked(
      mp_pool,
      #"5151515151515151515151515151515151515151515151515151515151",
      v,
      genesis_datum(),
    ),
  )
}

test mint_rejects_extra_lovelace() fail {
  launch_with_pool(pool_out(pool_floor_v4 + 1, supply, 1, 0, genesis_datum()))
}

test mint_rejects_short_lovelace() fail {
  launch_with_pool(pool_out(pool_floor_v4 - 1, supply, 1, 0, genesis_datum()))
}

/// Seeding quote at genesis WITHOUT the matching buy is refused — the v2
/// "free head start" bug, in quote terms.
test mint_rejects_free_quote_seed() fail {
  launch_with_pool(pool_out(pool_floor_v4, supply, 1, 12_500, genesis_datum()))
}

test mint_rejects_genesis_buy_wrong_tokens() fail {
  let d =
    gd(25_000, 990_128_421, 2_625, 250, mp_creator, mp_treasury, 100, 50, 2_500)
  launch_with_pool(pool_out(pool_floor_v4, 990_128_421, 1, 27_875, d))
}

test mint_rejects_genesis_buy_missing_fees() fail {
  let d = gd(25_000, 990_128_420, 0, 0, mp_creator, mp_treasury, 100, 50, 2_500)
  launch_with_pool(pool_out(pool_floor_v4, 990_128_420, 1, 25_000, d))
}

test mint_rejects_genesis_buy_flat_only_fee() fail {
  let d =
    gd(25_000, 990_128_420, 2_500, 250, mp_creator, mp_treasury, 100, 50, 2_500)
  launch_with_pool(pool_out(pool_floor_v4, 990_128_420, 1, 27_750, d))
}

test mint_rejects_genesis_buy_value_short_of_fees() fail {
  // datum claims 27,875 quote, pool holds 25,000
  let d =
    gd(25_000, 990_128_420, 2_625, 250, mp_creator, mp_treasury, 100, 50, 2_500)
  launch_with_pool(pool_out(pool_floor_v4, 990_128_420, 1, 25_000, d))
}

test mint_rejects_datum_names_other_policy() fail {
  let d =
    PoolDatumV4 {
      policy_id: #"c2c2c2c2",
      asset_name: mp_name,
      quote_reserve: 0,
      token_reserve: supply,
      platform_owed: 0,
      creator_owed: 0,
      creator_pkh: mp_creator,
      treasury_pkh: mp_treasury,
      creator_fee_bps: creator_fee_bps_v4,
      platform_fee_bps: platform_fee_bps_v4,
      platform_fee_flat: platform_fee_flat_v4,
    }
  launch_with_datum(d)
}

test mint_rejects_foreign_treasury() fail {
  launch_with_datum(
    gd(
      0,
      supply,
      0,
      0,
      mp_creator,
      mp_foreign_treasury,
      creator_fee_bps_v4,
      platform_fee_bps_v4,
      platform_fee_flat_v4,
    ),
  )
}

test mint_rejects_zero_platform_flat() fail {
  launch_with_datum(
    gd(0, supply, 0, 0, mp_creator, mp_treasury, creator_fee_bps_v4, platform_fee_bps_v4, 0),
  )
}

test mint_rejects_zero_platform_bps() fail {
  launch_with_datum(
    gd(0, supply, 0, 0, mp_creator, mp_treasury, creator_fee_bps_v4, 0, platform_fee_flat_v4),
  )
}

test mint_rejects_wrong_creator_bps() fail {
  launch_with_datum(
    gd(0, supply, 0, 0, mp_creator, mp_treasury, 500, platform_fee_bps_v4, platform_fee_flat_v4),
  )
}

/// The LUMP cohort's flat fee (10,000) is not this cohort's (2,500).
test mint_rejects_lump_cohort_flat_fee() fail {
  launch_with_datum(
    gd(0, supply, 0, 0, mp_creator, mp_treasury, creator_fee_bps_v4, platform_fee_bps_v4, 10_000),
  )
}

test mint_rejects_creator_equals_treasury() fail {
  launch_with_datum(
    gd(
      0,
      supply,
      0,
      0,
      mp_treasury,
      mp_treasury,
      creator_fee_bps_v4,
      platform_fee_bps_v4,
      platform_fee_flat_v4,
    ),
  )
}

test mint_rejects_creator_is_pool_script() fail {
  launch_with_datum(
    gd(
      0,
      supply,
      0,
      0,
      mp_pool,
      mp_treasury,
      creator_fee_bps_v4,
      platform_fee_bps_v4,
      platform_fee_flat_v4,
    ),
  )
}

test mint_rejects_short_creator_key() fail {
  launch_with_datum(
    gd(
      0,
      supply,
      0,
      0,
      #"c1c1c1c1",
      mp_treasury,
      creator_fee_bps_v4,
      platform_fee_bps_v4,
      platform_fee_flat_v4,
    ),
  )
}

test mint_rejects_junk_asset_in_genesis_pool() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(mp_policy, mp_name, supply)
      |> assets.add(mp_policy, pool_nft_name, 1)
      |> assets.add(
          #"9999999999999999999999999999999999999999999999999999999999",
          #"6a756e6b",
          1,
        )
  launch_with_pool(script_out(mp_pool, v, genesis_datum()))
}

/// A genesis pool quoted in $LUMP (the other cohort's asset) is a junk asset here.
test mint_rejects_lump_as_quote_asset() fail {
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(mp_policy, mp_name, supply)
      |> assets.add(mp_policy, pool_nft_name, 1)
      |> assets.add(
          #"73797786382c0832b5787a5b306f5308488f14571b7061f79396ad2c",
          #"4c756d70",
          100_000,
        )
  launch_with_pool(script_out(mp_pool, v, genesis_datum()))
}

test mint_rejects_two_pool_outputs() fail {
  mint_call(
    mp_seed(),
    Launch,
    mint_tx_out(mp_seed(), launch_mint(supply, 1), [good_pool(), good_pool()]),
  )
}

test mint_rejects_reference_script_on_pool() fail {
  let o = Output { ..good_pool(), reference_script: Some(#"00") }
  launch_with_pool(o)
}

// ══════════════════════════════════════════════════════════════════════════════
// Binding tests carried over from the 2026-09-12 adversarial review of the LUMP
// cohort. The
// `fail` tests pin guards the mutation pass found load-bearing but untested.
// ══════════════════════════════════════════════════════════════════════════════

/// Branch B of supply_ok is LIVE: a token name that sorts before
/// 000643b0504f4f4c (here #"0001") puts the NFT second in dict order.
test poc_mint_branch_b_token_name_sorting_before_nft() {
  let name = #"0001"
  let d =
    PoolDatumV4 {
      policy_id: mp_policy,
      asset_name: name,
      quote_reserve: 0,
      token_reserve: supply,
      platform_owed: 0,
      creator_owed: 0,
      creator_pkh: mp_creator,
      treasury_pkh: mp_treasury,
      creator_fee_bps: creator_fee_bps_v4,
      platform_fee_bps: platform_fee_bps_v4,
      platform_fee_flat: platform_fee_flat_v4,
    }
  let v =
    assets.from_lovelace(pool_floor_v4)
      |> assets.add(mp_policy, name, supply)
      |> assets.add(mp_policy, pool_nft_name, 1)
  let minted =
    assets.from_asset(mp_policy, name, supply)
      |> assets.add(mp_policy, pool_nft_name, 1)
  mint_call(mp_seed(), Launch, mint_tx_out(mp_seed(), minted, [script_out(mp_pool, v, d)]))
}

/// Test-gap probe: mint S+1, seat S, keep 1, plain datum — ONLY `q == total_supply_v4`
/// refuses this. It must be refused.
test poc_mint_rejects_extra_supply_kept_outside_pool() fail {
  mint_call(mp_seed(), Launch, mint_tx_out(mp_seed(), launch_mint(supply + 1, 1), [good_pool()]))
}

/// Test-gap probe: two minted names, neither the NFT → must be refused.
test poc_mint_rejects_two_tokens_no_nft() fail {
  let minted =
    assets.from_asset(mp_policy, mp_name, supply) |> assets.add(mp_policy, #"6f74686572", 1)
  mint_call(mp_seed(), Launch, mint_tx_out(mp_seed(), minted, [good_pool()]))
}

/// Test-gap probe: datum names the NFT as the token → pool would be born
/// value-inconsistent (frozen). Must be refused (d_name == token_name).
test poc_mint_rejects_datum_asset_name_mismatch() fail {
  let d =
    PoolDatumV4 {
      policy_id: mp_policy,
      asset_name: pool_nft_name,
      quote_reserve: 0,
      token_reserve: supply,
      platform_owed: 0,
      creator_owed: 0,
      creator_pkh: mp_creator,
      treasury_pkh: mp_treasury,
      creator_fee_bps: creator_fee_bps_v4,
      platform_fee_bps: platform_fee_bps_v4,
      platform_fee_flat: platform_fee_flat_v4,
    }
  launch_with_datum(d)
}

/// Test-gap probe: pool seats S (tokens_out = 0) but datum token_reserve lies (S−1).
/// Only `token_reserve == total_supply_v4 - tokens_out` refuses this.
test poc_mint_rejects_token_reserve_lie_with_full_seat() fail {
  launch_with_datum(
    gd(0, supply - 1, 0, 0, mp_creator, mp_treasury, creator_fee_bps_v4, platform_fee_bps_v4, platform_fee_flat_v4),
  )
}

/// Test-gap probe: launcher keeps 1 token with a SELF-CONSISTENT datum
/// (token_reserve = S-1, q = 0). Only `tokens_out == 0` in genesis_trade_ok refuses
/// this. Must be refused.
test poc_mint_rejects_free_allocation_with_consistent_datum() fail {
  launch_with_pool(
    pool_out(
      pool_floor_v4,
      supply - 1,
      1,
      0,
      gd(0, supply - 1, 0, 0, mp_creator, mp_treasury, creator_fee_bps_v4, platform_fee_bps_v4, platform_fee_flat_v4),
    ),
  )
}

/// Test-gap probe: genesis buy with the creator fee omitted (platform fee present).
/// Only `creator_owed == creator_fee(...)` refuses this. Must be refused.
test poc_mint_rejects_genesis_buy_missing_creator_fee_only() fail {
  let d = gd(25_000, 990_128_420, 2_625, 0, mp_creator, mp_treasury, 100, 50, 2_500)
  launch_with_pool(pool_out(pool_floor_v4, 990_128_420, 1, 27_625, d))
}

/// Test-gap probe: genesis pool output with NO datum must be refused.
test poc_mint_rejects_pool_without_datum() fail {
  let o = Output { ..good_pool(), datum: transaction.NoDatum }
  launch_with_pool(o)
}
