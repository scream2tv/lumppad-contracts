#!/usr/bin/env bash
# Build/check wrapper with the hash gate.
#
#   ./aikcheck.sh          -> aiken check
#   ./aikcheck.sh build    -> aiken build, THEN verify script hashes
#   ./aikcheck.sh hashes   -> verify script hashes only (needs a prior build)
#
# aiken renders COMPILE-ERROR diagnostics only to a real TTY — they vanish when
# stdout is piped or redirected. Where `script` can provide a PTY we use it and
# strip the ANSI escapes afterwards; otherwise aiken is run directly.
#
# Requires: aiken (on PATH), python3 for the hash gate.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
CMD="${1:-check}"

# The validator whose hash is recomputed independently below. Both cohorts name
# their pool validator the same; only the compiled bytes differ.
POOL_TITLE='lump_pool.lump_pool_v4.spend'

AIKEN="$(command -v aiken || true)"
if [ -z "$AIKEN" ] && [ -x "$HOME/bin/aiken" ]; then AIKEN="$HOME/bin/aiken"; fi
if [ -z "$AIKEN" ]; then
  echo "aikcheck: aiken not found on PATH — see https://aiken-lang.org/installation-instructions" >&2
  exit 127
fi

# ── The hash gate ─────────────────────────────────────────────────────────────
# `aiken check` CANNOT assert a script hash: an Aiken test cannot read
# plutus.json and a validator cannot hash itself. So a stdlib bump, a
# `plutus = "v3"` change, a compiler-flag change or an accidental edit would
# leave every test green while plutus.json quietly carried different bytes.
# That off-chain-to-on-chain seam is where the defects live, so it is enforced
# here, at build time, rather than asserted in prose.
#
# The pool hash is also RECOMPUTED from the compiled bytes rather than trusted
# from the blueprint's own `hash` field — the blueprint is written by the same
# compiler run that produced the bytes, so comparing only that would not catch a
# blueprint-writer bug. It is additionally the value applied off-chain to
# `lump_mint_v4`'s `pool_script_hash` PARAMETER, which nothing inside the Aiken
# tree can bind.
verify_hashes() {
  local expected="hashes.expected" bad=0 title want got rec want_pool
  if [ ! -f plutus.json ]; then
    echo "HASH GATE: plutus.json missing — run ./aikcheck.sh build first"
    return 1
  fi
  if [ ! -f "$expected" ]; then
    echo "HASH GATE: $expected missing"
    return 1
  fi
  echo "── hash gate ─────────────────────────────────────────────────────────"
  while read -r title want; do
    case "$title" in ''|\#*) continue ;; esac
    [ -z "$want" ] && continue
    # `title` comes out of a data file, so it is passed as an ARGUMENT and never
    # interpolated into the program text: a crafted hashes.expected must not be
    # able to run code in whoever verifies this repository.
    got=$(python3 -c '
import json,sys
d=json.load(open("plutus.json"))
for v in d["validators"]:
    if v["title"]==sys.argv[1]:
        print(v.get("hash","")); sys.exit(0)
print("MISSING")
' "$title")
    if [ "$got" = "$want" ]; then
      printf '  ok        %-45s %s\n' "$title" "$got"
    else
      printf '  MISMATCH  %-45s\n            expected %s\n            got      %s\n' \
        "$title" "$want" "$got"
      bad=1
    fi
  done < "$expected"

  rec=$(python3 -c '
import json,hashlib,sys
d=json.load(open("plutus.json"))
for v in d["validators"]:
    if v["title"]==sys.argv[1]:
        print(hashlib.blake2b(bytes.fromhex("03")+bytes.fromhex(v["compiledCode"]),digest_size=28).hexdigest())
        break
' "$POOL_TITLE")
  want_pool=$(awk -v t="$POOL_TITLE" '$1==t{print $2}' "$expected")
  if [ -n "$rec" ] && [ "$rec" = "$want_pool" ]; then
    echo "  ok        pool hash recomputed from compiledCode (blake2b-224, V3 tag)"
  else
    echo "  MISMATCH  pool hash recomputed = $rec"
    echo "            expected              = $want_pool"
    echo "            The blueprint's own 'hash' field and an independent"
    echo "            blake2b-224 over the bytes disagree, or the pin is stale."
    bad=1
  fi

  if [ "$bad" = "0" ]; then
    echo "  HASH GATE PASSED"
    return 0
  fi
  echo "  HASH GATE FAILED"
  return 1
}

if [ "$CMD" = "hashes" ]; then
  verify_hashes
  exit $?
fi

# Private temp files. A fixed /tmp path is something another user on the machine
# can pre-create as a symlink, which would redirect these writes.
LOG="$(mktemp "${TMPDIR:-/tmp}/aikcheck.XXXXXXXX")" || exit 1
CLEAN="$(mktemp "${TMPDIR:-/tmp}/aikcheck.XXXXXXXX")" || exit 1
trap 'rm -f "$LOG" "$CLEAN"' EXIT

if script -qfec true /dev/null >/dev/null 2>&1; then
  script -qfec "NO_COLOR=1 $AIKEN $CMD" "$LOG" >/dev/null 2>&1
  RC=$?
else
  NO_COLOR=1 "$AIKEN" "$CMD" >"$LOG" 2>&1
  RC=$?
fi

sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$LOG" > "$CLEAN"
if grep -q "Error\|error:" "$CLEAN"; then
  cat "$CLEAN"
else
  grep -E "FAIL|Summary|tests \|" "$CLEAN"
fi

if [ "$CMD" = "build" ] && [ "$RC" = "0" ]; then
  verify_hashes || RC=1
fi

exit $RC
