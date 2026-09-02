#!/usr/bin/env python3
"""Fix the two shared-memory bugs in ffn_dpagent2.c.

1. Torn counter publishes: wr32 wrote four bytes; the CP reads whole 8-byte groups.
   Replaced with a single 64-bit load/store pair (see new_accessors.txt).
2. Missing store barrier between the ring payload and the head/tail publish.

Replacement text is read from a FILE, never embedded in a python string -- doing the
latter is what turned intended \n escapes into real newlines and broke literals
earlier today.
"""
P = "/root/ffn-image-build/dpagent/ffn_dpagent2.c"
NEW = open("/root/ffn-image-build/dpagent/new_accessors.txt").read().rstrip() + "\n"
src = open(P).read()
open(P + ".bak-shm", "w").write(src)
lines = src.split("\n")

# --- 1. swap in the atomic accessors -------------------------------------------
start = end = None
for i, l in enumerate(lines):
    if l.startswith("static uint32_t rd32("):
        start = i
    elif start is not None and "Pull up to max bytes out of the CP->DP ring" in l:
        end = i
        break
if start is None or end is None:
    raise SystemExit("  !! accessor block not bounded (start=%s end=%s)" % (start, end))
lines = lines[:start] + NEW.split("\n") + lines[end:]
print("  replaced accessors at lines %d-%d" % (start + 1, end))

# --- 2. barrier before each publish -------------------------------------------
out = []
added = 0
for l in lines:
    s = l.strip()
    if s == "wr32(OFF_IN_TAIL, tail + (uint32_t)n);":
        out.append("\tdp_sync();\t\t/* our reads of the payload complete first */")
        added += 1
    elif s == "wr32(OFF_OUT_HEAD, head + (uint32_t)n);":
        out.append("\tdp_sync();\t\t/* payload visible before we advertise it */")
        added += 1
    out.append(l)
print("  inserted %d barrier(s) (expect 2)" % added)
if added != 2:
    raise SystemExit("  !! wrong barrier count -- not writing")

open(P, "w").write("\n".join(out))
print("  wrote %s (backup .bak-shm)" % P)
