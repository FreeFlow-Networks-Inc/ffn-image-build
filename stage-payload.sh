#!/bin/bash
# Stage a build payload from the offline code copy + the new daemons, so the FFN
# image can be built without a live FFN box (pairs with FFN_PRESEED=1).
#
#   sudo BUILD_ROOT=/mnt/clones/ffn-build ./stage-payload.sh /path/to/ffn-code-copy
set -euo pipefail
SRC="${1:?usage: stage-payload.sh /path/to/ffn-code-copy}"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/config.sh"
ND="$SRC/new-daemons"
mkdir -p "$PAYLOAD/units"

echo "== base artifacts from the code copy =="
for f in opt-ffn-ngfw-v1.tgz etc-ffn-ngfw.tgz; do
  cp -v "$SRC/$f" "$PAYLOAD/$f"
done
install -m 0755 "$SRC/ffn-cli" "$PAYLOAD/ffn-cli"; echo "  ffn-cli"

echo "== varlib seed + systemd units from ffn-build-ctx.tgz =="
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
tar xzf "$SRC/ffn-build-ctx.tgz" -C "$T"
CTX="$T/ffn-build-ctx"
cp -v "$CTX/varlib-seed.tgz" "$PAYLOAD/varlib-seed.tgz"
# units were captured as .cat (systemctl cat output) -> restore .service names,
# stripping the "# /path" comment lines systemctl prepends
for c in "$CTX/units/"*.cat; do
  [ -e "$c" ] || continue
  b=$(basename "$c" .cat)
  case "$b" in *.timer) out="$b";; *) out="$b.service";; esac
  grep -v '^# /' "$c" > "$PAYLOAD/units/$out"
  echo "  unit $out"
done

echo "== inject the new daemons into opt-ffn-ngfw-v2.tgz =="
W="$T/w"; mkdir -p "$W"
tar xzf "$SRC/opt-ffn-ngfw-v2.tgz" -C "$W"          # -> $W/ffn-ngfw-v2
DEST="$W/ffn-ngfw-v2"
for f in ffn_sysd.py ffn_satd.py ffn_watchdogd.py ffn_gryphon.py ffn_oct.py; do
  if [ -f "$ND/$f" ]; then install -m 0755 "$ND/$f" "$DEST/$f"; echo "  + $f"; fi
done
if [ -d "$ND/octeon-dp" ]; then
  mkdir -p "$DEST/octeon-dp"
  cp -a "$ND/octeon-dp/." "$DEST/octeon-dp/"
  echo "  + octeon-dp/ (dataplane sources + tests)"
fi
tar czf "$PAYLOAD/opt-ffn-ngfw-v2.tgz" -C "$W" ffn-ngfw-v2
echo "  repacked opt-ffn-ngfw-v2.tgz ($(stat -c %s "$PAYLOAD/opt-ffn-ngfw-v2.tgz") bytes)"

echo "== new units =="
for u in ffn-sysd ffn-satd ffn-watchdogd; do
  if [ -f "$ND/$u.service" ]; then cp -v "$ND/$u.service" "$PAYLOAD/units/$u.service"; fi
done

echo "== build scripts =="
cp "$HERE/config.sh" "$HERE/provision.sh" "$HERE/ffn-firstboot.sh" "$HERE/ffn-hwtune.sh" \
   "$HERE/ffn-selftest.sh" "$HERE/ffn-firstboot.service" "$HERE/ffn-selftest.service" \
   "$HERE/ffn-fips-selftest.service" "$HERE/ffn-recovery-menu.sh" "$HERE/ffn-recovery-menu.service" \
   "$HERE/requirements-v1.frozen" "$HERE/requirements-v2.frozen" "$PAYLOAD/"

echo
echo "PAYLOAD READY at $PAYLOAD"
ls -la "$PAYLOAD"
echo "units:"; ls -la "$PAYLOAD/units"
echo
echo "next:  FFN_PRESEED=1 FFN_SERIAL_BAUD=9600 BUILD_ROOT=$BUILD_ROOT sudo -E $HERE/build.sh"
