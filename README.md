# LumpPad Contracts

The Aiken smart contracts behind [LumpPad](https://lumppad.lumpfun.com), a token
launchpad on Cardano **mainnet** where every token is priced in a native token
rather than in ADA.

This repository exists so anyone can verify that the scripts holding user funds
are exactly the code published here. Nothing in it is required to *use* the
protocol — it is the source of truth for what the protocol *is*.

## Design

A launch mints the token's whole supply plus a 1-of-1 pool NFT under a
**one-shot** minting policy, and seats 100% of both in a single genesis pool
UTxO. That UTxO is the market for the life of the token.

- **One phase.** Constant-product pricing over a **permanent virtual quote
  offset**: price is `(quote_reserve + V) / token_reserve`. There is no curve to
  finish, no graduation, no mode flip. The pool you buy from on day one is the
  pool forever.
- **Liquidity is locked for life.** No withdraw redeemer exists. Quote leaves a
  pool only through `Sell` at the pool's own price, and through `Claim` of fees
  already charged to traders.
- **No free allocation.** The minting policy refuses a genesis pool that does
  not seat the entire supply. Every token outside the pool was bought on the
  curve, including the launcher's own first buy, which is priced exactly like
  any later buy.
- **ADA is not the price.** The pool UTxO carries a fixed lovelace floor for the
  ledger's min-UTxO rule, pinned exactly on every spend, never traded and never
  paid out.

Fees do not produce outputs on a trade. A fee output denominated in the quote
token would need its own min-UTxO on every trade, so `Buy` and `Sell` add the
fee to `platform_owed` / `creator_owed` in the datum instead. The validator pins
the pool's quote balance to `quote_reserve + platform_owed + creator_owed`, so
the accrued fees are real tokens sitting in the pool that the price does not
see. `Claim` is the only branch that pays anyone.

Half of every platform fee is destroyed or recycled on chain, enforced by the
validator rather than by policy — see the cohort table below.

## Quote cohorts

A **cohort** is one compiled (minting policy, pool validator) pair, quoted in
one asset, with its own scale constants. The quote asset is compiled into both
scripts, so a different quote asset is a different cohort with different hashes
and its own pool address. A token keeps deriving under the cohort that minted it
forever.

| | `cardano-v4` | `cardano-v4-night` | `cardano-v4-dong` |
|---|---|---|---|
| Quote asset | $LUMP | $NIGHT | $DONG |
| Quote decimals | 0 | 6 | 0 |
| Launch FDV (`virtual_quote_v4`) | 10,000,000 LUMP | 10,000 NIGHT | 2,500,000 DONG |
| Launch price per token | 0.01 LUMP | 0.00001 NIGHT | 0.0025 DONG |
| Flat platform fee per trade | 10,000 LUMP | 10 NIGHT | 2,500 DONG |
| Half of the platform fee goes to | an always-fail script (destroyed) | a buyback credential (buys and burns LUMP) | the same buyback credential |
| `Claim` may be submitted by | anyone | the creator or the treasury only | the creator or the treasury only |
| `Claim` payouts may go to | a key or a script credential | key credentials only | key credentials only |

All cohorts share every other parameter: 1,000,000,000 total supply at 0
decimals, a 3 ADA pool floor, 1.00% creator fee, 0.50% platform fee on top of
the flat fee, and a 0.30% LP fee retained in the reserves. The DONG cohort is
the NIGHT cohort's validators compiled against a different quote asset and
scale — nothing else changed (the `params_v4.ak` constants are the whole diff).

Why the non-LUMP cohorts pay a buyback credential instead of burning: burning
$NIGHT or $DONG would do nothing for $LUMP holders. The on-chain split is
identical — `platform_owed / 2` — but the recipient is a credential the operator
controls, and the LUMP bought with it is burned off chain. The half that is not
split off goes to the treasury in every cohort.

### Earlier cohorts

Before the launchpad opened, the contracts were compiled and used on mainnet a
couple of times while the treasury credential and the scale constants were still
being settled. Those earlier cohorts are not published here. Nothing trades on
them: their tokens were test launches, and what remains is a single drained pool
holding its ADA floor and the whole of its own test token. The cohorts above
are the ones every token you can buy today was minted under, and each has been
checked against the chain — the live pools sit at the addresses these bytes
produce, and the reference script the pools are spent through is byte-identical
to the `plutus.json` in this repository.

## Structure

```
cardano-v4/                 LUMP-quoted cohort
cardano-v4-night/           NIGHT-quoted cohort
cardano-v4-dong/            DONG-quoted cohort
  lib/lumpfun/
    params_v4.ak            every compiled-in constant, with identity tests
    math_v4.ak              constant-product quotes over the virtual offset
    fees_v4.ak              fee arithmetic and the Claim payout check
    pool_types.ak           pool datum (Constr 2, 11 fields) and redeemers
    types.ak                minting-policy redeemer
    test_helpers.ak         mock-transaction builders, test code only
  validators/
    lump_pool.ak            the pool: Buy, Sell, Claim
    minting_policy.ak       one-shot Launch-only policy
    burn.ak                 always-fail script (LUMP cohort only)
  aiken.toml, aiken.lock    compiler and dependency pins
  hashes.expected           the script hashes a build must reproduce
  plutus.json               the compiled blueprint
  aikcheck.sh               check / build wrapper with the hash gate
```

## Deployed script hashes (mainnet)

`cardano-v4` — LUMP-quoted:

| Script | Hash |
|---|---|
| `lump_pool_v4` (spend) | `60d7399911167a68d94731df96dfedc96436ee0d5bb2a7f0ef2981dc` |
| `lump_mint_v4` (mint, **unapplied**) | `b10e00f8ce685f14b3c730a09715480ac2ba9c369a97b69788729bfb` |
| `lump_burn` (always fails) | `22c9a103ed3f2fa97c982d76d6e2af50c5d54ac306983b196c8fcdab` |

Pool address `addr1w9sdwwvezyt856xegucal9klahykgdhwp4dm9flsau5crhqx9sd5x`
Burn address `addr1wy3vnggra5ljl2tunqkhd4hz4agvt422cvrfswcedj8um2c4cgds5`

`cardano-v4-night` — NIGHT-quoted:

| Script | Hash |
|---|---|
| `lump_pool_v4` (spend) | `02ef673acadeaec787de07c38a4cb6c6df392f276a1d1cb53ded5d51` |
| `lump_mint_v4` (mint, **unapplied**) | `7c860f5f82e829e59f4bb36882514111f60420a4fd9cc1cbb74d02e8` |

Pool address `addr1wypw7ee6et02a3u8mcru8zjvkmrd7wf0ya4p68948hk465gz0937a`

`cardano-v4-dong` — DONG-quoted:

| Script | Hash |
|---|---|
| `lump_pool_v4` (spend) | `0bdb1adb7aca6db2240d063da15340ef84f26c8dcc7722911be20295` |
| `lump_mint_v4` (mint, **unapplied**) | `7b79187fb26cbaa2c157791924f1c750dbdf78c59946cff886ab633a` |

Pool address `addr1wy9akxkm0t9xmv3yp5rrmg2ngrhcfunv3hx8wg53r03q99gv4qz6c`

Every address above was derived from the hash beside it, not copied. The pool
validator is unparameterised, so **every pool of a cohort shares one address** —
which is exactly why an address scan does not identify a token (see below).

The fee recipients are payment credentials, and any address carrying the
credential satisfies the validator:

| Credential | Hash |
|---|---|
| Treasury (every cohort) | `c79844a83ab36100765fbc19fb8d738a0d46657708f6ad08c8c637f3` |
| LUMP buyback (NIGHT and DONG cohorts) | `051ef6ae7c8c2d1d1dd78601cdcc097c28bf617ba621ea47c1d111bb` |

## Building and verifying

Built with [Aiken](https://aiken-lang.org) `v1.1.17+c3a7fba`, Plutus `v3`,
`aiken-lang/stdlib v3.1.0` (pinned in `aiken.lock`).

```sh
cd cardano-v4          # or cardano-v4-night, cardano-v4-dong
aiken check            # 138 tests here, 149 in each of the NIGHT and DONG cohorts
aiken build            # regenerates plutus.json
```

`aiken check` cannot assert a script hash — an Aiken test cannot read
`plutus.json`, and a validator cannot hash itself. A stdlib bump or a compiler
change would leave every test green while the compiled bytes moved. So the hash
gate lives at build time instead: `./aikcheck.sh build` rebuilds and then
verifies every hash in `hashes.expected`.

To verify a hash independently of both Aiken and this repository, take the
`compiledCode` of a validator from `plutus.json` and compute:

```
blake2b-224( 0x03 ‖ compiledCode )
```

The `0x03` prefix is the Plutus V3 language tag. That is the script hash the
ledger uses, and it must equal the entry in `hashes.expected`.

## Protocol parameters

From `lib/lumpfun/params_v4.ak`. Quote amounts are in the quote asset's **base
units**, so a NIGHT figure is 10⁶ times its display value.

| Constant | `cardano-v4` | `cardano-v4-night` | `cardano-v4-dong` |
|---|---|---|---|
| `total_supply_v4` | 1,000,000,000 | 1,000,000,000 | 1,000,000,000 |
| `virtual_quote_v4` | 10,000,000 | 10,000,000,000 | 2,500,000 |
| `pool_floor_v4` | 3,000,000 lovelace | 3,000,000 lovelace | 3,000,000 lovelace |
| `creator_fee_bps_v4` | 100 | 100 | 100 |
| `platform_fee_bps_v4` | 50 | 50 | 50 |
| `platform_fee_flat_v4` | 10,000 | 10,000,000 | 2,500 |
| `lp_fee_bps_v4` | 30 | 30 | 30 |

Worked genesis vectors. The token side is identical wherever the buy is the same
fraction of `virtual_quote_v4` (the flat fee is always 1/1000 of it), except
where floor division at a smaller scale drops a few tokens:

| Buy at genesis | Tokens out |
|---|---|
| 10,000 LUMP / 10 NIGHT | 996,006 |
| 2,500 DONG | 995,807 |
| 100,000 LUMP / 100 NIGHT / 25,000 DONG | 9,871,580 |
| 1,000,000 LUMP / 1,000 NIGHT / 250,000 DONG | 90,661,089 |

The quote is priced net of the LP fee, the full input enters the reserve, and
amounts out are floored, so `k` strictly grows on every trade.

## Identifying a token: recompute, never scan

Every pool of a cohort sits at one shared address, and the pool validator reads
the token's policy id **from its own datum**. So finding a UTxO at the pool
address that holds an asset named `000643b0504f4f4c` proves only that the UTxO
holds the NFT its own datum names. It does **not** prove the token was minted by
this protocol. Anyone can mint a lookalike under their own script, write a datum
of their choosing, and park it at the shared address.

`lump_mint_v4` is parameterised by `(one_shot_utxo, pool_script_hash)`, so a
genuine policy id is a pure function of one of its mint transaction's inputs and
the cohort's canonical pool hash:

1. Read the token's mint transaction and list its inputs.
2. For each input, apply `[one_shot_utxo, pool_script_hash]` to the **unapplied**
   mint CBOR from `plutus.json`, using the cohort's pool hash above.
3. Hash the applied script. If it equals the token's policy id, the launch is
   genuine, and the input you just used is its seed UTxO.
4. If no input reproduces the policy id under any cohort, the token is not a
   LumpPad launch you can trade — either a lookalike parked at the shared
   address, whatever its datum claims, or one of the pre-launch test tokens
   described under "Earlier cohorts".

Never fall back to matching on the asset name or the pool address.

## Testing

`aiken check` runs 138 tests in `cardano-v4` and 149 in each of
`cardano-v4-night` and `cardano-v4-dong`, all unit tests over mock transactions. Every number in a test is re-derived from
`params_v4.ak` rather than copied from another cohort, because a constant that
happens to compile makes a rejection test pass for the wrong reason.

Tests named `poc_*` are deliberate: they **document behaviour the cohort
accepts**, so that a future cohort which closes one of them turns the test into
a visible failure rather than a silent change. They are not aspirational.

## Security model, briefly

What the validator enforces on every spend, on every branch:

- Exactly one pool UTxO in the transaction, and no other script input.
- The spent UTxO carries the 1-of-1 NFT its datum names.
- The datum mirrors the real value on the way in and on the way out.
- Whole-datum reconstruction: the four mutable fields move, the seven config
  fields are copied from the input datum and frozen for life.
- Exactly one continuation, at the exact address spent from, with no stake part,
  no reference script, and no extra assets.
- The platform fee schedule and the treasury credential equal the compiled
  constants, so a self-seeded pool cannot trade fee-free or redirect the
  platform's fee.
- No mint under the pool's own policy.

The minting policy additionally pins, at genesis: the whole supply seated, the
exact lovelace floor, the cohort fee schedule and treasury, a genesis buy
priced exactly like any later buy, and distinct recipients.

## Known limitations

These are accepted properties of the deployed cohorts, not open bugs. They are
listed because a contract you cannot audit honestly is not worth publishing.

- **`Claim` is permissionless on the LUMP cohort.** Anyone may submit it. The
  money can only move to the compiled-in credentials, but a payout may be
  directed to a *script* address carrying the same hash as a key recipient,
  which nobody can spend from. A griefer pays the min-UTxO themselves and gains
  nothing; the loss is the fees accrued since the last claim. It is mitigated by
  claiming often. **The NIGHT and DONG cohorts close this**: a claim must be
  signed by the creator or the treasury, and every payout must land at a
  verification-key credential.
- **A position worth less than the flat fee cannot be sold.** `Sell` requires
  the seller to be paid something after fees. This is the flat fee's nature; the
  interface says so before a trade is attempted.
- **A buy of one base unit can return zero tokens** and still costs the flat
  fee. The interface refuses trades that quote zero.
- **The lovelace floor is pinned exactly.** If Cardano's `coinsPerUTxOByte` ever
  rose far enough that 3 ADA no longer covered the pool output, existing pools
  would be frozen rather than drained.
- **Native-script wallets cannot trade**, because the transaction shape admits
  only the pool as a script input.

## Audit status

**No third-party audit has been performed.** The contracts were reviewed
internally, including a mutation pass over the validators whose findings are
pinned as tests here, and the deployed hashes are reproducible from this source.
That is not the same as an external audit, and this section should not be
removed until one exists.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
