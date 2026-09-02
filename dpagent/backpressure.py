#!/usr/bin/env python3
"""Stop the DP->CP ring from dropping output under burst.

out_put() advanced head unconditionally, so when the shell produced faster than the
CP drained (e.g. `ls -laR`), head ran past tail by more than the ring size and the CP
resynced by skipping forward -- discarding bytes, sometimes including the marker that
-c waits for. Symptom: intermittent empty output or "no marker within Ns".

Fix: apply real backpressure. out_put writes only what fits and reports the rest, and
the main loop stops reading the pty master while the ring is nearly full. Unread
bytes simply stay in the pty's own buffer, which is exactly where they should wait.
"""
P = "/root/ffn-image-build/dpagent/ffn_dpagent2.c"
s = open(P).read()

old_put = """static void out_put(const unsigned char *src, size_t n)
{
	uint32_t head = rd32(OFF_OUT_HEAD);
	size_t i;

	if (n > OUT_SIZE)
		n = OUT_SIZE;
	for (i = 0; i < n; i++)
		ring[OUT_OFF + ((head + i) % OUT_SIZE)] = src[i];
	wr32(OFF_OUT_HEAD, head + (uint32_t)n);
}"""

new_put = """static size_t out_space(void)
{
	uint32_t head = rd32(OFF_OUT_HEAD);
	uint32_t tail = rd32(OFF_OUT_TAIL);
	uint32_t used = head - tail;

	if (used >= OUT_SIZE)
		return 0;
	return OUT_SIZE - used;
}

/* Write only what fits and return how much was written. The caller must not read
 * more from the pty than out_space() allows, so nothing is ever silently dropped --
 * the bytes wait in the pty buffer instead. */
static size_t out_put(const unsigned char *src, size_t n)
{
	uint32_t head = rd32(OFF_OUT_HEAD);
	size_t space = out_space();
	size_t i;

	if (n > space)
		n = space;
	for (i = 0; i < n; i++)
		ring[OUT_OFF + ((head + i) % OUT_SIZE)] = src[i];
	if (n)
		wr32(OFF_OUT_HEAD, head + (uint32_t)n);
	return n;
}"""

old_read = """		/* shell output -> the CP */
		if (master >= 0) {
			n = read(master, buf, sizeof(buf));"""
new_read = """		/* shell output -> the CP, but only as much as the ring can hold:
		 * reading more would force us to drop it. */
		if (master >= 0 && out_space() >= 512) {
			size_t room = out_space();

			if (room > sizeof(buf))
				room = sizeof(buf);
			n = read(master, buf, room);"""

old_call = """			if (n > 0) {
				out_put(buf, (size_t)n);
				busy = 1;
			} else if (n == 0) {"""
new_call = """			if (n > 0) {
				out_put(buf, (size_t)n);
				busy = 1;
			} else if (n == 0) {"""

n = 0
if old_put in s:
    s = s.replace(old_put, new_put, 1); n += 1
if old_read in s:
    s = s.replace(old_read, new_read, 1); n += 1
# the "shell exited" notice ignores the return value; make that explicit
s = s.replace("out_put((const unsigned char *)msg, sizeof(msg) - 1);",
              "(void)out_put((const unsigned char *)msg, sizeof(msg) - 1);")
open(P, "w").write(s)
print("  applied %d/2 core edits" % n)
