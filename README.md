# mgz

A tiny gzip compressor and decompressor written in [Mere](https://merelang.org/),
in pure Mere with no external libraries. The output is real gzip: the system
`gunzip` accepts what `deflate.mere` writes, and `inflate.mere` decompresses
what the system `gzip` writes.

```sh
# compress: produces <file>.mgz (valid gzip)
mere -c deflate.mere > d.c && clang -O2 d.c -o deflate && ./deflate README.md
gunzip -c README.md.mgz | diff - README.md   # round-trips

# decompress a real .gz
gzip -c README.md > r.gz
mere -c inflate.mere > i.c && clang -O2 i.c -o inflate && ./inflate r.gz
diff README.md.mgz.out README.md 2>/dev/null || diff r.gz.out README.md
```

## What's implemented

**`inflate.mere`** — a DEFLATE decompressor (RFC 1951) plus the gzip container
(RFC 1952). One canonical Huffman decoder serves all three block types —
stored, fixed-Huffman, and dynamic-Huffman — because the fixed tables are just
a particular set of code lengths. It skips the optional gzip header fields and
verifies the trailer's CRC-32 and length against the decompressed output.

**`deflate.mere`** — a DEFLATE compressor: a bit writer that packs
variable-length codes LSB-first across byte boundaries, a greedy longest-match
LZ77 that emits length/distance back-references, and fixed-Huffman literal and
length codes. Fixed Huffman plus greedy matching leaves roughly 2x on the table
versus `gzip -9`'s dynamic Huffman — a completeness gap, not a bug.

Both are byte-for-byte interoperable with the system tools and with each other,
on the interpreter and the C backend alike.

## Why it exists

mgz is a dogfood — a real program written to find out where the language rubs.
Everything the two files need had landed as separate features first: bitwise
operators, hex literals, and a binary-safe file reader/writer (`read_file_bytes`
/ `write_file_bytes`, since a NUL-terminated string would truncate compressed
data at its first zero byte). Composing them into a real format flushed out
three code-generation bugs and one large performance bug — see [PAIN.md](PAIN.md).
