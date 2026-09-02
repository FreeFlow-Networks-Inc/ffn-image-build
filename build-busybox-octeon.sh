#!/bin/bash
# Build a FULL static busybox for the OCTEON (MIPS64 big-endian, n64 ABI).
#
# WHY: the CP's root filesystem is the vendor's CentOS-7 BE userland, whose busybox
# is a reduced build -- no sed, tar, xargs, vi, less, wget, nc, awk-as-applet. Those
# tools exist NOWHERE on the CP, which makes the control plane painful to work in
# (shell pipelines silently produce nothing because `sed` is missing). One full
# static busybox restores ~300 applets in a single self-contained binary with no
# library dependencies to fight.
#
# GPL, built from upstream source by us -- fits the own-code/open-content rule.
set -e
BB=busybox-1.36.1
D=/root/ffn-image-build
cd "$D"
CROSS=mips64-linux-gnuabi64-

if [ ! -f "$BB.tar.bz2" ]; then
  echo "== fetching $BB =="
  curl -fsSLO "https://busybox.net/downloads/$BB.tar.bz2"
fi
echo "== sha256 of the tarball (record it) =="
sha256sum "$BB.tar.bz2"

rm -rf "$BB"
tar xf "$BB.tar.bz2"
cd "$BB"

echo "== configure =="
make ARCH=mips CROSS_COMPILE=$CROSS defconfig >/dev/null

# Static, so it does not depend on the vendor glibc at all.
sed -i 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' .config
# These do not cross-build cleanly against modern headers / need extra libs.
for off in CONFIG_TC CONFIG_FEATURE_TC_INGRESS CONFIG_PAM CONFIG_SELINUX \
           CONFIG_BUSYBOX_EXEC_PATH CONFIG_FEATURE_WTMP CONFIG_FEATURE_UTMP; do
  sed -i "s/^$off=y$/# $off is not set/" .config
done
make ARCH=mips CROSS_COMPILE=$CROSS oldconfig >/dev/null 2>&1 || true
grep -E '^CONFIG_STATIC|^CONFIG_TC=' .config || true

echo "== build =="
make ARCH=mips CROSS_COMPILE=$CROSS -j"$(nproc)" 2>&1 | tail -20

echo "== result =="
ls -la busybox
file busybox
./busybox --list 2>/dev/null | wc -l | sed 's/^/  applets: /' || \
  echo "  (cannot run a MIPS binary here; applet count checked on target)"
