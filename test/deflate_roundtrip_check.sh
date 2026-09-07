#!/bin/sh
# test/deflate_roundtrip_check.sh — every block this encoder writes can be read back.
#
# WHY IT EXISTS. `deflate_dynamic` cannot encode every block: RFC 1951 gives the
# CODE-LENGTH alphabet at most 7 bits, where the literal and distance trees get 15, and
# a frequency distribution that needs an 8-bit code-length code has no dynamic block.
# `build_lengths` deliberately does not limit anything -- its comment says the caller
# checks -- and `deflate_body` checked the other two trees and never checked this one, so
# the encoder walked `canon_codes`'s 8-entry array at index 8 and ABORTED.
#
# It is DATA DEPENDENT, which is why nothing met it: of 16x16, 32x32, 48x48, 64x64 and
# 128x128 images of random bytes, only one size hit it. So this sweeps sizes rather than
# testing one, and it tests the property that matters -- inflate(deflate(x)) == x -- which
# holds whether the block came out dynamic or stored, and would also have caught the
# second half of the bug: after the abort became a graceful empty return, the caller that
# had bypassed `deflate_body` wrote an EMPTY block, and a corrupt output is quieter than
# a crash.
#
#   MERE=/path/to/mere sh test/deflate_roundtrip_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || [ -x "$MERE" ] || { echo "roundtrip: set MERE to a mere binary" >&2; exit 1; }
CC="${CC:-clang}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/rt.mere" <<'MERE'
import "inflate.mere";
import "deflate.mere";

// Random bytes: incompressible, so the Huffman trees are as wide as they get and the
// code-length alphabet is pushed hardest. A run of zeros would never reach the case.
let make = fn (n: int) -> fn (seed: int) ->
  let v = vec_new () in
  let rec go = fn (i: int) -> fn (x: int) ->
    if i == n then ()
    else
      let x2 = (1103515245 * x + 12345) % 2147483648 in
      let _ = vec_push v (x2 % 256) in
      go (i + 1) x2 in
  let _ = go 0 seed in v;

let same = fn (a) -> fn (b) ->
  if vec_len a != vec_len b then false
  else
    let rec go = fn (i: int) ->
      if i == vec_len a then true
      else if (vec_get a i : int) != (vec_get b i : int) then false
      else go (i + 1) in
    go 0;

let bad = vec_new ();
let one_vec = fn (src) ->
  let n = vec_len src in
  let enc = deflate_body src in
  // An empty block is the "cannot write it dynamically" signal, and the fallback should
  // already have turned it into a stored one. Seeing it here means a caller bypassed the
  // fallback -- which is the second half of the bug this file pins.
  let _ = if vec_len enc == 0 && n > 0 then
            let _ = vec_push bad n in print ("EMPTY n=" ++ str_of_int n) else () in
  let back = inflate enc 0 in
  if same src back then ()
  else let _ = vec_push bad n in
       print ("MISMATCH n=" ++ str_of_int n ++ " got " ++ str_of_int (vec_len back));
let one = fn (n: int) -> fn (seed: int) -> one_vec (make n seed);

// The sizes around the one that failed, plus a few seeds, because which trees come out
// is a property of the bytes and not only of how many there are.
let rec sweep = fn (n: int) ->
  if n > 4096 then ()
  else
    let _ = one n 20260907 in
    let _ = one n 12345 in
    let _ = one n 99991 in
    sweep (n * 2 + 7) in
let _ = sweep 1;
let _ = one 0 1;

// AND THE STREAM THAT ACTUALLY FOUND IT. The sweep above does not reproduce the
// code-length overflow -- measured: it passes against the broken encoder -- because
// random bytes are not what a real caller produces. This is mpng's filtered scanlines
// for a 32x32 image of random pixels, captured once and committed; see test/data.
let trig = bytes_of_hex (read_file "TRIGGER_PATH");
let tv = vec_of_bytes trig;
let _ = one_vec tv;
print (if vec_len bad == 0 then "deflate_roundtrip: ok" else "deflate_roundtrip: FAILED")
MERE

rc=0
cp "$ROOT/inflate.mere" "$ROOT/deflate.mere" "$TMP/"
sed -i.bak "s|TRIGGER_PATH|$ROOT/test/data/cl_overflow.hex|" "$TMP/rt.mere"
out=$("$MERE" "$TMP/rt.mere" 2>&1) || { echo "roundtrip: interp did not run"; echo "$out" | head -3; rc=1; }
echo "  interp: $(echo "$out" | grep deflate_roundtrip | tail -1)"
case "$out" in *"deflate_roundtrip: ok"*) ;; *) rc=1 ;; esac

if command -v "$CC" >/dev/null 2>&1; then
  if "$MERE" -c "$TMP/rt.mere" > "$TMP/rt.c" 2>"$TMP/e" && "$CC" -O2 -w "$TMP/rt.c" -o "$TMP/rt" -lm 2>>"$TMP/e"; then
    out=$("$TMP/rt" 2>&1)
    echo "  C:      $(echo "$out" | grep deflate_roundtrip | tail -1)"
    case "$out" in *"deflate_roundtrip: ok"*) ;; *) rc=1 ;; esac
  else
    echo "  C:      did not build"; head -3 "$TMP/e"; rc=1
  fi
else
  echo "  C:      SKIP (no $CC)"
fi

[ "$rc" = 0 ] && echo "PASS deflate_roundtrip" || echo "FAIL deflate_roundtrip"
exit $rc
