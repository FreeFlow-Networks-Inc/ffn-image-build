#!/usr/bin/env bash
# Recompute kernel cmdline (hugepages/isolcpus/iommu) for the ACTUAL cpu+ram.
# Effective on the next boot. Safe defaults on small machines (no core isolation).
set -uo pipefail
CORES=$(nproc)
RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)

# hugepages: ~25% of RAM as 2M pages, capped 4096 (8 GiB), floor 256
HP=$(( RAM_KB / 4 / 2048 )); [ "$HP" -gt 4096 ] && HP=4096; [ "$HP" -lt 256 ] && HP=256

CMD="intel_iommu=on iommu=pt default_hugepagesz=2M hugepagesz=2M hugepages=${HP} transparent_hugepage=never"

# core isolation for the dataplane only on appliance-class CPUs (>=16 threads):
# isolate the upper half for DP/worker cores, keep 0-3 for housekeeping/IRQ.
if [ "$CORES" -ge 16 ]; then
  START=$(( CORES / 2 )); END=$(( CORES - 1 ))
  CMD="${CMD} isolcpus=managed_irq,domain,${START}-${END} rcu_nocbs=${START}-${END} nohz_full=${START}-${END} irqaffinity=0-3"
fi

# Serial baud is platform-specific (PA-3200/5200 chassis run 9600); the image
# build persists it so re-tuning on first boot cannot revert to 115200.
BAUD=115200
[ -r /etc/ffn-ngfw/serial-baud ] && BAUD="$(cat /etc/ffn-ngfw/serial-baud)"
CMD="${CMD} console=tty0 console=ttyS0,${BAUD}n8"

sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${CMD}\"|" /etc/default/grub
echo "ffn-hwtune: cores=${CORES} ram_kb=${RAM_KB} -> hugepages=${HP}$([ "$CORES" -ge 16 ] && echo ", isolcpus=${START}-${END}")"
command -v update-grub >/dev/null 2>&1 && update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
