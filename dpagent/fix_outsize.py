#!/usr/bin/env python3
"""Make the out-ring size a power of two, and correct two comments I got wrong.

CONFIRMED BUG (found by the adversarial review, not by me): OUT_SIZE was 0xC000 =
49152 = 3 * 16384, which is NOT a power of two. Both sides map a monotonic 32-bit
counter to an index with `counter % OUT_SIZE`, and 2^32 % 0xC000 = 0x4000, so the
map is DISCONTINUOUS at the counter wrap: f(0xFFFFFFFF) = 0x3FFF but f(0) = 0x0 --
it jumps back by 0x4000 instead of forward by 1. Worse, both sides' bulk copies
split only at the OUT_SIZE boundary (`first = min(n, OUT_SIZE - idx)`), never at the
2^32 boundary, so any transfer straddling the wrap runs linearly straight through
the discontinuity and corrupts. IN_SIZE 0x2000 is a power of two, so the in-ring was
always immune. 0x8000 restores 2^32 % SIZE == 0. Costs 16 KB of ring; buys
correctness at the wrap.

COMMENT CORRECTIONS. The review refuted two things I asserted:
 * the store barrier is NOT a visibility fix here -- /dev/mem is opened O_SYNC, which
   Linux maps UNCACHED (uncached_access/pgprot_noncached), so stores already reach
   memory in program order; and cnMIPS L1 is write-through with L2C as the IO
   coherence point. Keeping the sync is harmless, but the comment claiming it fixes
   visibility was wrong and would mislead.
 * the torn-counter publish is REAL (four byte stores vs an 8-byte read), but the
   catastrophic 65535-byte over-read I described was overstated: the call-site
   geometry prevents that consequence. The atomic accessors stay -- a non-atomic
   publish of a counter the other side reads whole is worth removing on its own --
   but the justification should not overclaim.
"""
import re

C = "/root/ffn-image-build/dpagent/ffn_dpagent2.c"
src = open(C).read()
open(C + ".bak-outsize", "w").write(src)

n = 0
if "#define OUT_SIZE 0xC000" in src:
    src = src.replace("#define OUT_SIZE 0xC000",
                      "#define OUT_SIZE 0x8000\t/* MUST be a power of two: the index is\n"
                      "\t\t\t\t * counter % OUT_SIZE and the counter wraps at\n"
                      "\t\t\t\t * 2^32. 0xC000 made that map discontinuous at\n"
                      "\t\t\t\t * the wrap (2^32 %% 0xC000 = 0x4000). */", 1)
    n += 1
    print("  OUT_SIZE 0xC000 -> 0x8000")

old_sync = """/*
 * Store barrier. The ring payload must be visible to the CP BEFORE the head that
 * advertises it, otherwise the CP is told about bytes it cannot yet read. v1 of this
 * agent had such a barrier and v2 lost it; this puts it back.
 */"""
new_sync = """/*
 * Store barrier before publishing a head/tail.
 *
 * NOTE: this is belt-and-braces, not a visibility fix. /dev/mem is opened with
 * O_SYNC, which Linux maps UNCACHED (uncached_access -> pgprot_noncached), so these
 * stores already reach memory in program order; cnMIPS L1 is write-through and L2C
 * is the coherence point for inbound PCIe reads. An earlier comment here claimed the
 * barrier was required for the CP to see the payload -- that was wrong. It is kept
 * because it costs nothing on this path and documents the ordering the protocol
 * depends on.
 */"""
if old_sync in src:
    src = src.replace(old_sync, new_sync, 1)
    n += 1
    print("  corrected the barrier comment (it is not a visibility fix)")

old_claim = """ * The CP reads these fields through a PCIe window that byte-reverses each aligned
 * 64-bit word, so it necessarily loads a WHOLE 8-byte group at a time. The previous
 * wr32() published a counter as four separate byte stores, which the CP could catch
 * half-updated. That is not theoretical: taking out_head from 0x0000FFFF to
 * 0x00010000 stores MSB-first, so a CP read landing after two bytes sees
 * 0x0001FFFF -- 65535 larger than the true value. The CP then reads ring bytes that
 * were never written and drives its tail past head, which is the unrecoverable
 * overshoot state."""
new_claim = """ * The CP reads these fields through a PCIe window that byte-reverses each aligned
 * 64-bit word, so it necessarily loads a WHOLE 8-byte group at a time. The previous
 * wr32() published a counter as four separate byte stores, which the CP could catch
 * half-updated: taking out_head from 0x0000FFFF to 0x00010000 stores MSB-first, so a
 * read landing after two bytes yields 0x0001FFFF -- forward of the truth. The tear
 * itself is real and worth removing. (An earlier comment here went further and
 * claimed it caused an unrecoverable tail-past-head overshoot; adversarial review
 * showed the call-site geometry prevents that particular consequence, so the tear is
 * a latent hazard rather than a demonstrated failure path.)"""
if old_claim in src:
    src = src.replace(old_claim, new_claim, 1)
    n += 1
    print("  softened the overstated torn-counter consequence")

open(C, "w").write(src)
print("  wrote %s (%d edit(s), backup .bak-outsize)" % (C, n))
