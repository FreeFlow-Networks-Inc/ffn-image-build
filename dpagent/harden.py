#!/usr/bin/env python3
"""Two hardening items the adversarial review identified, beyond the size fix.

1. WIDTH BUG. `ring[OUT_OFF + ((head + i) % OUT_SIZE)]` has head as uint32_t and i as
   size_t, so on this LP64 target `head + i` is evaluated in 64 bits and does NOT wrap
   at 2^32 -- while the head published two lines later, `head + (uint32_t)n`, does. For
   a burst straddling the counter wrap the indices written and the head advertised
   disagree. Making OUT_SIZE a power of two already neutralises this (2^32 % SIZE == 0
   makes the two agree), but the code should not depend on that coincidence: someone
   changing the size later would silently reintroduce it.

2. WEDGE GUARD. out_space() computes `used = head - tail` and returns 0 when
   used >= OUT_SIZE. If the CP's tail ever runs AHEAD of head, that subtraction
   underflows to a huge number, out_space() reports a permanently full ring, the poll
   loop stops draining the pty, and head can never advance to recover -- the agent is
   wedged for good. Re-syncing head to the CP loses the few bytes in flight and keeps
   the session, which is the right trade for a control channel.
"""
P = "/root/ffn-image-build/dpagent/ffn_dpagent2.c"
src = open(P).read()
open(P + ".bak-harden", "w").write(src)
n = 0

old_i = "\t\tdst[i] = ring[IN_OFF + ((tail + i) % IN_SIZE)];"
new_i = "\t\tdst[i] = ring[IN_OFF + ((uint32_t)(tail + (uint32_t)i) % IN_SIZE)];"
if old_i in src:
    src = src.replace(old_i, new_i, 1); n += 1
    print("  in_take: index arithmetic pinned to 32 bits")

old_o = "\t\tring[OUT_OFF + ((head + i) % OUT_SIZE)] = src[i];"
new_o = "\t\tring[OUT_OFF + ((uint32_t)(head + (uint32_t)i) % OUT_SIZE)] = src[i];"
if old_o in src:
    src = src.replace(old_o, new_o, 1); n += 1
    print("  out_put: index arithmetic pinned to 32 bits")

old_sp = """	uint32_t head = rd32(OFF_OUT_HEAD);
	uint32_t tail = rd32(OFF_OUT_TAIL);
	uint32_t used = head - tail;

	if (used >= OUT_SIZE)
		return 0;
	return OUT_SIZE - used;"""
new_sp = """	uint32_t head = rd32(OFF_OUT_HEAD);
	uint32_t tail = rd32(OFF_OUT_TAIL);
	uint32_t used;

	/*
	 * If the CP's tail has run AHEAD of our head the CP has mis-tracked. Reading
	 * that as a full ring would WEDGE us permanently: out_space() would return 0,
	 * the poll loop would stop draining the pty, and head could never advance to
	 * catch up. Re-sync to the CP instead -- losing the few bytes in flight is
	 * strictly better than losing the session, which is the only way in.
	 */
	if ((int32_t)(head - tail) < 0) {
		wr32(OFF_OUT_HEAD, tail);
		return OUT_SIZE;
	}

	used = head - tail;
	if (used >= OUT_SIZE)
		return 0;
	return OUT_SIZE - used;"""
if old_sp in src:
    src = src.replace(old_sp, new_sp, 1); n += 1
    print("  out_space: added the tail-ahead-of-head wedge guard")

open(P, "w").write(src)
print("  wrote %s (%d edit(s), backup .bak-harden)" % (P, n))
if n != 3:
    raise SystemExit("  !! expected 3 edits, got %d" % n)
