#!/bin/bash
# Wait for the Buildroot run to finish, then report outcome + image details.
BR=/root/ffn-image-build/buildroot-2025.02.9
LOG=/root/ffn-image-build/br-build.log
while pgrep -f "make -j12" >/dev/null 2>&1; do sleep 20; done
echo "=== build finished ==="
echo "  steps completed: $(grep -cE '^>>>' "$LOG")"
echo "  last package   : $(grep -E '^>>>' "$LOG" | tail -1)"
echo "--- errors ---"
grep -iE '^make(\[[0-9]+\])?: \*\*\*|^Error [0-9]+$' "$LOG" | tail -8
echo "  (empty above = clean)"
echo "--- images ---"
ls -la "$BR/output/images/" 2>/dev/null
echo "--- toolchain sanity ---"
CC=$(ls "$BR"/output/host/bin/mips64-*-gcc 2>/dev/null | head -1)
echo "  cc: $CC"
[ -n "$CC" ] && "$CC" -dumpmachine
echo "--- a target binary, to confirm arch/endianness ---"
for f in bin/bash usr/bin/python3 usr/sbin/sshd usr/bin/sort; do
  p="$BR/output/target/$f"
  [ -e "$p" ] && echo "  $f: $(file -b "$p" | cut -c1-88)"
done
