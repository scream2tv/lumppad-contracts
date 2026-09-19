// ══════════════════════════════════════════════════════════════════════════════
// LumpPad LUMP burn — an always-fail script.
//
// $LUMP's minting policy is a snek.fun one-shot Plutus script with no burn path,
// so LUMP cannot be destroyed. The next best thing is provable, permanent
// unspendability: this validator has no handler that can ever succeed, so any
// value sent to its script address is locked for the life of the chain.
//
// `lump_pool_v4.Claim` requires HALF of every platform fee claim to be paid to
// this script's credential (`params_v4.burn_script_hash_v4`), so the burn is
// enforced on chain rather than promised. The hash is pinned in hashes.expected
// and the protocol generator refuses to run if the constant and the compiled
// script disagree.
// ══════════════════════════════════════════════════════════════════════════════

validator lump_burn {
  else(_) {
    fail
  }
}
