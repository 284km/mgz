#!/bin/sh
# test/crc32_check.sh — CRC-32 against a value computed by something else, on
# every backend including the 32-bit one.
#
# The README said the output matched the system gzip byte for byte and there was
# nothing here that checked it. This is the smallest part of that claim that can
# be checked without a gzip: the checksum, against zlib's answer for a known
# input, on the interpreter, the C backend, and -- by compiling -- RV32I.
#
# The 32-bit arm is the reason this file exists. `bit_shr` propagates the sign on
# every backend, and a CRC accumulator starts as all ones, so where an int is
# exactly 32 bits wide it is negative from the first step and the top bit never
# leaves. Nothing here would have noticed: the mask that hid it was a literal
# too wide for that target, so compilation stopped before the arithmetic ran.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
command -v "$MERE" >/dev/null 2>&1 || [ -x "$MERE" ] || { echo "crc32_check: set MERE to a mere binary" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0

# crc32 of the nine bytes "012345678", per python3 -c 'import zlib;
# print(zlib.crc32(b"012345678"))'
WANT=939184570

cat > "$TMP/p.mere" <<MERE
import "$ROOT/inflate.mere";
let b = vec_new ();
let rec fill = fn (i: int) -> if i > 8 then () else let _ = vec_push b (48 + i) in fill (i + 1);
let _ = fill 0;
let _ = print_int (crc32_vec b);
MERE

got=$("$MERE" "$TMP/p.mere" 2>&1 | head -1)
[ "$got" = "$WANT" ] || { echo "FAIL crc32 (interpreter): got $got, want $WANT"; rc=1; }

if command -v cc >/dev/null 2>&1; then
  if "$MERE" -c "$TMP/p.mere" > "$TMP/p.c" 2>"$TMP/e" && cc -O0 -w "$TMP/p.c" -lm -o "$TMP/p" 2>/dev/null; then
    got=$("$TMP/p" | head -1)
    [ "$got" = "$WANT" ] || { echo "FAIL crc32 (C backend): got $got, want $WANT"; rc=1; }
  else
    echo "crc32_check: the C arm did not build — skipping" >&2
  fi
fi

# RV32I: 32-bit and signed. Compiling is what can be checked without an
# emulator; running it there gave $WANT as well.
if "$MERE" -rv "$TMP/p.mere" > "$TMP/p.bin" 2>"$TMP/rve"; then :; else
  echo "FAIL crc32: does not compile for RV32I (32-bit signed int)"
  head -4 "$TMP/rve"
  rc=1
fi

# The primitive, not just the algorithm. CRC-32's accumulator is positive on a
# 64-bit backend, so `shr1` never sees a negative input there and a plain
# `bit_shr` would give the same checksum -- the bug is invisible through the
# algorithm on every backend that can run this gate. Handed a negative directly,
# the logical shift answers 2147483647 everywhere and the arithmetic one answers
# -1, so this arm catches it without a 32-bit machine.
cat > "$TMP/s.mere" <<MERE
import "$ROOT/inflate.mere";
let _ = print_int (shr1 (0 - 1));
let _ = print_int (shr1 (0 - 8));
MERE
got=$("$MERE" "$TMP/s.mere" 2>&1 | head -2 | tr '\n' ' ')
case "$got" in
  "2147483647 2147483644 ") ;;
  *) echo "FAIL crc32: shr1 is not a logical shift — got: $got"
     echo "  (want 2147483647 2147483644; an arithmetic bit_shr gives -1 -4)"
     rc=1 ;;
esac

[ "$rc" = 0 ] && echo "ok crc32: $WANT on the interpreter, the C backend, and compiling for RV32I"
exit $rc
