#!/bin/sh
# test/gunzip_check.sh — what mgunzip produces, against what gzip produces.
#
# The README has claimed since the beginning that the output matches the system
# gzip byte for byte, and nothing here checked it: crc32_check.sh checks the
# checksum and deflate_roundtrip_check.sh checks that our compressor's output
# is accepted. Neither would notice a decompressor that produced the wrong
# bytes with the right CRC-32 -- and the CRC is computed over the same wrong
# bytes, so it would agree with itself.
#
# It also records the peak memory, because that is the reason this file was
# written: the output is one int per byte, and a 4 MB layer costs about 71 MB
# of vector. A bound rather than a print, so a change that gives it back has
# something to be measured against.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
[ -x "$MERE" ] || command -v "$MERE" >/dev/null 2>&1 || { echo "set MERE to a mere binary" >&2; exit 2; }
command -v gzip >/dev/null 2>&1 || { echo "needs gzip" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

"$MERE" -c "$ROOT/mgunzip.mere" > "$TMP/u.c" 2>"$TMP/e" || { echo "FAIL: mgunzip emit"; sed -n 1,8p "$TMP/e"; exit 1; }
cc -O2 -o "$TMP/mgunzip" "$TMP/u.c" 2>/dev/null || { echo "FAIL: cc"; exit 1; }
say 0 "mgunzip builds"

# Inputs of three shapes: text that compresses well, a file with long matches,
# and one that is incompressible. A decompressor can be wrong on one and right
# on the others -- stored blocks, fixed Huffman and dynamic Huffman are three
# different paths through the same function.
mkdir -p "$TMP/in"
cp "$ROOT/README.md" "$TMP/in/text"
cat "$ROOT/inflate.mere" "$ROOT/deflate.mere" "$ROOT/inflate.mere" > "$TMP/in/repeats"
head -c 300000 /dev/urandom > "$TMP/in/random"
# A file big enough that the memory number means something.
i=0; : > "$TMP/in/big"
while [ "$i" -lt 60 ]; do cat "$ROOT/inflate.mere" "$ROOT/deflate.mere" >> "$TMP/in/big"; i=$((i + 1)); done

for f in text repeats random big; do
  gzip -c "$TMP/in/$f" > "$TMP/$f.gz"
  ( cd "$TMP" && "$TMP/mgunzip" "$TMP/$f.gz" > "$TMP/$f.say" 2>&1 )
  cmp -s "$TMP/$f.gz.out" "$TMP/in/$f"
  say $? "$f: mgunzip's output is byte for byte what gzip was given ($(wc -c < "$TMP/in/$f" | tr -d ' ') bytes)"
  grep -q "crc OK" "$TMP/$f.say"; say $? "$f: and the trailer checks out"
done

# A gzip stream this did not produce, from a different compressor, so the
# check is not just "our writer and our reader agree".
if command -v python3 >/dev/null 2>&1; then
  python3 - "$TMP/in/text" "$TMP/py.gz" <<'PY'
import gzip, sys
open(sys.argv[2], "wb").write(gzip.compress(open(sys.argv[1], "rb").read(), 9))
PY
  ( cd "$TMP" && "$TMP/mgunzip" "$TMP/py.gz" >/dev/null 2>&1 )
  cmp -s "$TMP/py.gz.out" "$TMP/in/text"
  say $? "a stream from another compressor comes out the same"
fi

# Peak memory, against the size of what it decompressed.
out_bytes=$(wc -c < "$TMP/in/big" | tr -d ' ')
case "$(uname -s)" in
  Darwin) /usr/bin/time -l "$TMP/mgunzip" "$TMP/big.gz" 2>"$TMP/time" >/dev/null
          peak=$(awk '/maximum resident set size/{print $1}' "$TMP/time") ;;
  *)      /usr/bin/time -v "$TMP/mgunzip" "$TMP/big.gz" 2>"$TMP/time" >/dev/null
          peak=$(( $(awk '/Maximum resident set size/{print $6}' "$TMP/time") * 1024 )) ;;
esac
ratio=$(( peak / (out_bytes / 1024) / 1024 ))
echo "  --    $out_bytes bytes out, peak RSS $peak bytes, ${ratio}x the output"
# One byte per byte for the output, plus the input, plus the copy that freezes
# the output for writing. Eight is comfortably above that and comfortably below
# the eleven a vector of ints cost -- so going back to one is caught here.
[ "$ratio" -lt 8 ]; say $? "peak memory is under 8x what it decompressed"

# Poison: a decompressor that drops a byte still has a self-consistent CRC only
# if the CRC is computed over what it produced -- which it is. So the poison is
# on the OUTPUT, and the comparison against gzip is what catches it.
sed 's|let _ = bytebuf_push out sym in loop ()|let _ = (if bytebuf_len out == 1000 then () else (let _ = bytebuf_push out sym in ())) in loop ()|' \
  "$ROOT/inflate.mere" > "$TMP/poison_inflate.mere"
cmp -s "$ROOT/inflate.mere" "$TMP/poison_inflate.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
cp "$ROOT/crc32.mere" "$TMP/crc32.mere"   # the copy imports it from beside itself
sed "s|import \"./inflate.mere\";|import \"$TMP/poison_inflate.mere\";|" "$ROOT/mgunzip.mere" > "$TMP/poison_mgunzip.mere"
if "$MERE" -c "$TMP/poison_mgunzip.mere" > "$TMP/pu.c" 2>/dev/null && cc -O2 -o "$TMP/mgunzip-poison" "$TMP/pu.c" 2>/dev/null; then
  ( cd "$TMP" && "$TMP/mgunzip-poison" "$TMP/text.gz" > "$TMP/poison.say" 2>&1 )
  cmp -s "$TMP/text.gz.out" "$TMP/in/text" \
    && { echo "  FAIL  a dropped byte came out identical, so this gate proves nothing"; fail=1; } \
    || echo "  ok    a decompressor that drops one byte is caught"
  grep -q "crc MISMATCH" "$TMP/poison.say" \
    && echo "  ok    and its own checksum disagrees too" \
    || echo "  --    (its checksum still agreed, which is why the comparison is the check)"
else
  echo "  FAIL  the poisoned mgunzip did not build"; fail=1
fi

[ "$fail" = 0 ] && echo "gunzip PASS" || echo "gunzip FAIL"
exit "$fail"
