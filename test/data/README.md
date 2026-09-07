# test/data

`cl_overflow.hex` — 3,104 bytes of filtered PNG scanlines, as hex.

It is here because **randomly generated input does not reproduce the bug it
pins**, which was measured rather than assumed: a sweep of random byte strings
from 1 to 4096 bytes, three seeds each, passes against the broken encoder. This
stream does not, and it is what a real caller produced — mpng's per-row filter
choice over a 32x32 image of random pixels, which is what a renderer writing a
frame of shaded spheres hands it.

The bug: RFC 1951 gives the code-length alphabet at most 7 bits, `build_lengths`
does not limit anything, and `deflate_body` checked the literal and distance
trees and not this one. `canon_codes` then walked an 8-entry array at index 8.

A fixture and not a generator, because the input that finds this is a property
of a filter heuristic in another project. Regenerating it would mean
reimplementing that heuristic here, and then the test would be pinned to the
reimplementation rather than to the bug.
