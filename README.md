# mgz

A tiny gzip compressor and decompressor written in [Mere](https://merelang.org/),
in pure Mere with no external libraries. The output is real gzip: the system
`gunzip` accepts what `deflate.mere` writes, and `inflate.mere` decompresses
what the system `gzip` writes.

```sh
# compress: produces <file>.mgz (valid gzip)
mere -c mgzip.mere > z.c && clang -O2 z.c -o mgzip && ./mgzip README.md
gunzip -c README.md.mgz | diff - README.md   # round-trips

# decompress a real .gz
gzip -c README.md > r.gz
mere -c mgunzip.mere > u.c && clang -O2 u.c -o mgunzip && ./mgunzip r.gz
diff r.gz.out README.md
```

## Using it as a package

`inflate.mere` and `deflate.mere` are **modules** — definitions only, no
program — so another project can vendor mgz and import them. `mgzip.mere` and
`mgunzip.mere` are the CLIs, and they use the same import.

```sh
cd my_app
git clone https://github.com/284km/mgz .mere_modules/mgz
```

```mere
import "mgz/inflate.mere";
import "mgz/deflate.mere";

let squeezed = deflate_body data;      // raw DEFLATE (RFC 1951)
let member   = deflate_gzip data;      // ...in a gzip member (RFC 1952)
let back     = inflate member (gzip_body_start member);
let sum      = crc32_vec data;
```

| export | from | meaning |
|---|---|---|
| `inflate data start` | inflate.mere | raw DEFLATE, decoding from byte offset `start` |
| `is_gzip data` | inflate.mere | does this look like a gzip member |
| `gzip_body_start data` | inflate.mere | offset of the DEFLATE stream past the header |
| `gunzip data` | inflate.mere | the two above, composed |
| `gunzip_ok data out` | inflate.mere | verify the CRC-32 / ISIZE trailer |
| `crc32_vec bytes` | either | CRC-32 of a byte vector |
| `deflate_body data` | deflate.mere | raw DEFLATE, dynamic Huffman with a stored fallback |
| `deflate_stored data` | deflate.mere | raw DEFLATE, stored blocks only (always valid) |
| `deflate_gzip data` | deflate.mere | `deflate_body` in a gzip member |

## What's implemented

**`inflate.mere`** — a DEFLATE decompressor (RFC 1951) plus the gzip container
(RFC 1952). One canonical Huffman decoder serves all three block types —
stored, fixed-Huffman, and dynamic-Huffman — because the fixed tables are just
a particular set of code lengths. It skips the optional gzip header fields and
verifies the trailer's CRC-32 and length against the decompressed output.

**`deflate.mere`** — a DEFLATE compressor: a bit writer that packs
variable-length codes LSB-first across byte boundaries, a greedy longest-match
LZ77 that emits length/distance back-references, and a per-block dynamic
Huffman stage. Symbol frequencies drive a node-pool Huffman tree; the codes are
made canonical (RFC 1951 §3.2.2) and the code-length alphabet is itself
run-length coded (symbols 16/17/18) into the block header. If a code would
exceed the format's 15-bit limit the block falls back to a stored (uncompressed)
block. The result is competitive with `gzip -9` — on a real text file it lands
within a few percent, and on some repetitive inputs it edges ahead.

Both are byte-for-byte interoperable with the system tools and with each other,
on the interpreter and the C backend alike.

## Why it exists

mgz is a dogfood — a real program written to find out where the language rubs.
Everything the two files need had landed as separate features first: bitwise
operators, hex literals, and a binary-safe file reader/writer (`read_file_bytes`
/ `write_file_bytes`, since a NUL-terminated string would truncate compressed
data at its first zero byte). Composing them into a real format flushed out
three code-generation bugs and one large performance bug — see [PAIN.md](PAIN.md).

## Checking it

```sh
MERE=/path/to/mere sh test/crc32_check.sh
```

CRC-32 against zlib's answer for a known input, on the interpreter, the C
backend, and compiling for RV32I — plus one arm that checks `shr1` is a
*logical* shift rather than the arithmetic one `bit_shr` gives.

That last arm is the reason the file exists. A CRC accumulator starts as all
ones, so on a backend whose int is exactly 32 bits wide it is negative from the
first step and an arithmetic shift never lets the top bit go. On a wider int the
accumulator is positive and the same code is correct, so the algorithm cannot
show the difference anywhere this gate can run — handed a negative directly, the
shift can.


## One byte per byte

`inflate` holds bytes in a `ByteBuf`, not a `Vec` of ints. A vector of ints
costs **eight bytes per byte** on a 64-bit backend, so a 4 MB gzip member was
32 MB of input and 71 MB of output before anything was written anywhere. The
stdlib says as much about `read_file_bytes` — *"Costs eight bytes per byte;
prefer `read_bytes`"* — and nothing here had read it.

Measured by `test/gunzip_check.sh`, decompressing 2.2 MB:

| | peak RSS | |
|---|---|---|
| `Vec` of ints | 26.0 MB | 11× the output |
| `ByteBuf` | 9.1 MB | 4× the output |

The gate asserts the ratio, so going back to one is caught rather than noticed
later by whoever runs out of memory.

**What it costs:** `inflate.mere` no longer compiles for RV32I, because a byte
buffer has no lowering there. That backend is the reason `crc32_check.sh`
exists — it found a real bug, where an int is exactly 32 bits wide and a CRC
accumulator is negative from its first step — so the arithmetic moved into
`crc32.mere`, which uses no byte buffer and is still asked that question there.
It was written out twice before, identically, in `inflate.mere` and
`deflate.mere`; a program importing both got two definitions with the later one
quietly winning.

## The check that was missing

The README claimed from the beginning that the output matched the system gzip
byte for byte, and nothing here checked it. `crc32_check.sh` checks the
checksum and `deflate_roundtrip_check.sh` checks that our own compressor's
output is accepted — **neither would notice a decompressor that produced the
wrong bytes with the right CRC-32**, because the CRC is computed over the same
wrong bytes and agrees with itself.

`test/gunzip_check.sh` compares against `gzip` on four shapes of input — text,
long matches, incompressible, and one big enough for the memory number to mean
something — and on a stream from a third compressor, so it is not just our
writer and our reader agreeing. Its poison drops one byte in the middle: the
comparison catches it, and the daemon's own checksum happens to as well.

```sh
MERE=/path/to/mere sh test/gunzip_check.sh
```
