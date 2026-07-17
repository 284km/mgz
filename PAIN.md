# PAIN — what mgz found in the language

A dogfood earns its keep by the bugs it surfaces. Writing a real gzip
compressor and decompressor in pure Mere flushed out four issues, all fixed
upstream. Every one of them was invisible on the interpreter and appeared only
when the emitted C was compiled — the shadow a dense, deeply-recursive,
capture-heavy program casts on the closure-lifting machinery.

## P1 — reserved-name parameter, sanitized on only one path (fixed, v0.1.51)

A parameter named `index` is fine in Mere, but `index` is a function in C's
`<strings.h>`, so the C backend rewrites such names to `index_` at every
reference. It did so at reference sites but not at the *declaration* site: the
generated function declared `index` and its body used `index_` — undeclared.
The fix sanitizes the declaration too, on both the lifted-function path and the
anonymous-closure-adapter path that a deeply curried inner function takes (the
Huffman decoder is curried enough to hit the latter).

## P2 — a local variable stolen by a namesake in another function (fixed, v0.1.51)

A plain local `p` was silently dropped from an inner loop's captures, so the
generated call referenced a `p` not in scope. The capture-exclusion filter
("don't capture inner-function *names*") used a global, last-write-wins map of
inner-function names — and a different function elsewhere happened to have an
inner helper also called `p`. The fix scopes the check per-function.

## P3 — a zero value for a type that doesn't exist (fixed, v0.1.51)

A `match` whose result type is a `Vec` needs a fallthrough value for the
non-exhaustive default (an abort path that must still type-check). The code
mangled the container type name and produced `(Vec___heap_int){0}` — but a
`Vec` is a pointer, not a by-value struct, and no such type exists. Pointer
containers now fall through to a null pointer.

## P4 — curried inner functions were never uncurried (fixed, v0.1.52)

The big one. Inflating a 1 MB file used 484 MB of memory. It was not the byte
representation (a million plain vector pushes cost 17 MB); it was that a curried
*inner* recursive function — the Huffman decoder, four arguments, called once
per symbol — compiled to a chain of anonymous closures, each partial
application and each recursive step allocating a closure environment from the
region, which never frees. Top-level curried functions had gotten an uncurried
"direct" twin much earlier; inner functions had not. Extending that to inner
functions dropped a curried-inner-rec-fn microbenchmark from 769 MB to 1.46 MB
(~530x) and this decompressor from 484 MB to 34 MB, output unchanged.

## Still open (not language bugs)

- Match speed: the LZ77 matcher is a naive window scan (fine natively, slow
  interpreted). A real implementation would use a hash chain.
- Window size: LZ77 back-references never cross a single DEFLATE block, and the
  compressor emits one block for the whole input, so very large files are not
  chunked. `gzip` streams 32 KB windows across many blocks.
