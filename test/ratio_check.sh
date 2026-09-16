#!/bin/sh
# test/ratio_check.sh — does the compressor actually COMPRESS?
#
# Every other check here asks whether the output is CORRECT: gunzip accepts it,
# the CRC agrees, the bytes come back. A compressor that emits stored blocks
# passes all of them and is useless, and that is not hypothetical -- it is what
# this one did. A 10,000-byte slice of a container layer that gzip takes to
# 1,366 came out at 10,023, BIGGER than it went in, because one code-length
# code wanted 8 bits and the whole block fell back to stored.
#
# So this one compares SIZE against gzip, on real input, at several sizes. The
# bound is 110%: measured, this sits between 99% and 103%, and a stored block
# is 250%+. It is not trying to pin the ratio to the last byte -- a change that
# costs 5% is a decision, not a defect -- but "within a tenth of gzip" cannot
# be met by a stored block, by a match finder that finds nothing, or by a tree
# that gives up.
#
# THE SIZES MATTER. The bug only appeared above about 8 KB: the small, tidy
# inputs the other checks use all fit in one tidy tree. An input smaller than
# the window also cannot show a match finder that walks its chain into the
# future -- which was the OTHER bug found here the same afternoon.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
[ -x "$MERE" ] || command -v "$MERE" >/dev/null 2>&1 || { echo "set MERE to a mere binary" >&2; exit 2; }
command -v gzip >/dev/null 2>&1 || { echo "needs gzip as the oracle" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "needs python3 to generate the witness" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

"$MERE" -c "$ROOT/mgzip.mere" > "$TMP/mgzip.c" 2>"$TMP/e" || { echo "FAIL: mere -c"; sed -n 1,8p "$TMP/e"; exit 1; }
cc -O2 -o "$TMP/mgzip" "$TMP/mgzip.c" 2>/dev/null || { echo "FAIL: cc"; exit 1; }

# Real input, made from this repository so the check carries its own data: a
# tar of the sources is a mix of text, repetition and structure, which is what
# a container layer is too.
( cd "$ROOT" && tar cf "$TMP/src.tar" *.mere test ) 2>/dev/null
[ -s "$TMP/src.tar" ] || { echo "FAIL: no input"; exit 1; }
# Padded up so the largest case is past the 32 KiB window, which is where a
# chain that walks into the future stops finding anything.
cat "$TMP/src.tar" "$TMP/src.tar" "$TMP/src.tar" "$TMP/src.tar" > "$TMP/big.bin"

for n in 2000 10000 100000 $(wc -c < "$TMP/big.bin" | tr -d ' '); do
  head -c "$n" "$TMP/big.bin" > "$TMP/in.bin"
  rm -f "$TMP/in.bin.mgz"
  ( cd "$TMP" && "$TMP/mgzip" in.bin >/dev/null 2>&1 )
  [ -s "$TMP/in.bin.mgz" ] || { say 1 "$n bytes: nothing was written"; continue; }
  gzip -c "$TMP/in.bin" > "$TMP/in.gz"
  ours=$(wc -c < "$TMP/in.bin.mgz" | tr -d ' ')
  theirs=$(wc -c < "$TMP/in.gz" | tr -d ' ')
  # Correct first: a small file that is also wrong is not a win.
  gunzip -c "$TMP/in.bin.mgz" | cmp -s - "$TMP/in.bin"
  say $? "$n bytes: gunzip gives the input back"
  [ "$ours" -lt "$n" ]; say $? "$n bytes: smaller than the input ($ours)"
  # 110% of gzip, integer arithmetic.
  [ $((ours * 100)) -le $((theirs * 110)) ]
  say $? "$n bytes: $ours against gzip's $theirs ($((ours * 100 / theirs))%)"
done

# THE WITNESS FOR THE TREE THAT GIVES UP.
#
# The sources above are compressed well by every version of this file, working
# or not -- the fallback is DATA DEPENDENT, and none of them happen to trigger
# it. This one does: a tar-shaped file of long NUL runs, fixed-width headers
# and a small alphabet, which is what a container image layer looks like and
# what was actually being compressed when the bug showed up.
#
# Generated rather than recorded, from a fixed seed, so the repository carries
# the witness as four lines instead of a blob -- and so the shape that triggers
# it is legible.
python3 - "$TMP/witness.bin" <<'PYEOF'
import random, sys
random.seed(11)
names = [b"./usr/lib/libc.so.6", b"./bin/busybox", b"./etc/passwd", b"./lib/ld-musl.so"]
out, i = bytearray(), 0
while len(out) < 400000:
    hdr = (names[i % len(names)] + b"%04d" % i).ljust(100, b"\0")
    hdr += b"0000644\0000000\0000000\0" + (b"%011o\0" % random.randint(0, 20000))
    out += hdr.ljust(512, b"\0")
    body = bytes(random.choice(b"\0\0\0\0\0\0\0\0abcdefghijklmnop\x01\x02\x12\x30")
                 for _ in range(random.choice([512, 1024, 512])))
    out += body.ljust((len(body) + 511) // 512 * 512, b"\0")
    i += 1
open(sys.argv[1], "wb").write(bytes(out[:400000]))
PYEOF
rm -f "$TMP/witness.bin.mgz"
( cd "$TMP" && "$TMP/mgzip" witness.bin >/dev/null 2>&1 )
gzip -c "$TMP/witness.bin" > "$TMP/witness.gz"
ours=$(wc -c < "$TMP/witness.bin.mgz" | tr -d ' ')
theirs=$(wc -c < "$TMP/witness.gz" | tr -d ' ')
gunzip -c "$TMP/witness.bin.mgz" | cmp -s - "$TMP/witness.bin"
say $? "the layer-shaped witness comes back byte for byte"
[ $((ours * 100)) -le $((theirs * 110)) ]
say $? "and is $ours against gzip's $theirs ($((ours * 100 / theirs))%) -- a stored block here is 400053"

[ "$fail" = 0 ] && echo "ratio PASS" || echo "ratio FAIL"
exit "$fail"
