#!/bin/sh
# test/zlib_check.sh — zlib_inflate against Python's zlib, interp and C.
#
#   MERE=/path/to/mere sh test/zlib_check.sh [--poison]
#
# zlib_inflate exists for git, which stores every object as a zlib stream and,
# inside a pack, stores them back to back. So what is checked is not only the
# bytes that come out, but WHERE the stream ended: a decoder whose end offset
# is one byte off inflates the first object of a pack correctly and then reads
# the second one from the wrong place.
#
#   shapes       stored (level 0), fixed and dynamic Huffman, empty, text,
#                incompressible, long runs -- the three block paths
#   end offset   == the stream's length, for every shape
#   back to back two streams concatenated: the second is inflated from the
#                end offset the first one reported, as a pack reader would
#   checksum     a stream whose Adler-32 is changed still inflates, and says bad
#   header       a header with a preset dictionary, or a wrong method, is bad
#
# --poison moves the end offset by one and requires the back-to-back check
# to fail (the shape checks compare the offset too; this one is the check
# that would be MISSING if they were the only ones).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-mere}"
[ -x "$MERE" ] || command -v "$MERE" >/dev/null 2>&1 || { echo "set MERE to a mere binary" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "needs python3 (its zlib is the oracle)" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'PY'
import os, zlib, sys
d = sys.argv[1]
text = b"".join(b"line %d of some text that repeats a little\n" % i for i in range(3000))
shapes = {
    "empty": (b"", 6), "tiny": (b"a", 6), "text6": (text, 6), "text1": (text, 1),
    "text9": (text, 9), "stored": (text[:70000], 0), "random": (os.urandom(100000), 6),
    "runs": (b"x" * 200000 + b"y" * 3 + b"x" * 5000, 9),
}
for name, (raw, lvl) in shapes.items():
    z = zlib.compress(raw, lvl)
    open(f"{d}/{name}.raw", "wb").write(raw)
    open(f"{d}/{name}.z", "wb").write(z)
    open(f"{d}/{name}.len", "w").write(str(len(z)))
# two streams back to back, with a byte of junk after, as in a pack
a, b = zlib.compress(text[:5000], 6), zlib.compress(b"second object\n" * 40, 6)
open(f"{d}/pair.z", "wb").write(a + b + b"\x00")
open(f"{d}/pair.a", "wb").write(text[:5000]); open(f"{d}/pair.b", "wb").write(b"second object\n" * 40)
open(f"{d}/pair.alen", "w").write(str(len(a))); open(f"{d}/pair.blen", "w").write(str(len(b)))
# a bad checksum, a preset-dictionary header, a wrong method
z = bytearray(zlib.compress(text[:3000], 6)); z[-1] ^= 1
open(f"{d}/badsum.z", "wb").write(z); open(f"{d}/badsum.raw", "wb").write(text[:3000])
open(f"{d}/fdict.z", "wb").write(bytes([0x78, 0xBB]) + b"\0" * 8)   # FDICT set, FCHECK ok
open(f"{d}/method.z", "wb").write(bytes([0x77, 0x01]) + b"\0" * 8)  # CM = 7
PY

run_checks() {  # $1 = directory holding inflate.mere and test/zlib_driver.mere
  "$MERE" -c "$1/test/zlib_driver.mere" > "$TMP/d.c" 2>"$TMP/e" || { echo "FAIL: emit"; sed -n 1,8p "$TMP/e"; return 1; }
  cc -O2 -w -o "$TMP/drv" "$TMP/d.c" || { echo "FAIL: cc"; return 1; }
  bad=0
  for how in interp c; do
    drv() { if [ $how = interp ]; then "$MERE" "$1/test/zlib_driver.mere" "$2" "$3" "$4"; else "$TMP/drv" "$2" "$3" "$4"; fi; }
    for name in empty tiny text6 text1 text9 stored random runs; do
      got="$(drv "$1" "$TMP/$name.z" 0 "$TMP/out")"
      want="$(cat "$TMP/$name.len") ok $(wc -c < "$TMP/$name.raw" | tr -d ' ')"
      [ "$got" = "$want" ] || { echo "FAIL shape $name ($how): '$got', want '$want'"; bad=$((bad + 1)); continue; }
      cmp -s "$TMP/out" "$TMP/$name.raw" || { echo "FAIL shape $name ($how): bytes differ"; bad=$((bad + 1)); }
    done
    got="$(drv "$1" "$TMP/pair.z" 0 "$TMP/out")"
    end1="${got%% *}"
    if [ "$end1" != "$(cat "$TMP/pair.alen")" ] || ! cmp -s "$TMP/out" "$TMP/pair.a"; then
      echo "FAIL back to back ($how): first stream '$got'"; bad=$((bad + 1))
    else
      got="$(drv "$1" "$TMP/pair.z" "$end1" "$TMP/out")"
      want="$(( end1 + $(cat "$TMP/pair.blen") )) ok"
      case "$got" in "$want "*) cmp -s "$TMP/out" "$TMP/pair.b" || { echo "FAIL back to back ($how): second bytes"; bad=$((bad + 1)); } ;;
        *) echo "FAIL back to back ($how): second stream '$got', want '$want ...'"; bad=$((bad + 1)) ;; esac
    fi
    got="$(drv "$1" "$TMP/badsum.z" 0 "$TMP/out")"
    case "$got" in *" bad "*) cmp -s "$TMP/out" "$TMP/badsum.raw" || { echo "FAIL checksum ($how): bytes"; bad=$((bad + 1)); } ;;
      *) echo "FAIL checksum ($how): a changed Adler-32 was '$got'"; bad=$((bad + 1)) ;; esac
    for h in fdict method; do
      got="$(drv "$1" "$TMP/$h.z" 0 "$TMP/out")"
      [ "$got" = "0 bad 0" ] || { echo "FAIL header $h ($how): '$got'"; bad=$((bad + 1)); }
    done
  done
  [ $bad -eq 0 ] || { echo "zlib: $bad problem(s)"; return 1; }
  echo "ok | zlib: 8 shapes, back to back, checksum, 2 headers -- interp and C"
}

if [ "${1:-}" = "--poison" ]; then
  mkdir -p "$TMP/p/test"; cp "$ROOT"/*.mere "$TMP/p/"; cp "$ROOT/test/zlib_driver.mere" "$TMP/p/test/"
  python3 - "$TMP/p/inflate.mere" <<'PY' || { echo "FAIL poison: fragment not found"; exit 1; }
import sys
p = sys.argv[1]; s = open(p).read(); a = "    (out, dend + 4, stored == adler32 out (bytebuf_len out));"
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, "    (out, dend + 5, stored == adler32 out (bytebuf_len out));"))
PY
  if run_checks "$TMP/p" > "$TMP/poison.log" 2>&1; then echo "FAIL poison: an end offset one byte off passed"; exit 1; fi
  grep -q "^FAIL back to back" "$TMP/poison.log" || { echo "FAIL poison: CAUGHT FOR THE WRONG REASON"; head -3 "$TMP/poison.log"; exit 1; }
  echo "ok | poison caught (end offset one byte off)"; exit 0
fi

run_checks "$ROOT" || exit 1
echo "zlib PASS"
