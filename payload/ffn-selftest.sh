#!/usr/bin/env bash
# Post-boot self-test: confirms the management plane auto-loaded. Prints a clear
# line to the console (visible on serial) so a headless boot can be verified.
set -uo pipefail
ok(){ echo -e "\033[1;32m$*\033[0m"; }
bad(){ echo -e "\033[1;31m$*\033[0m"; }

echo "=== FFN SELFTEST $(date -u +%FT%TZ) ==="
# wait up to ~120s for the WebUI/API (first boot does key/cert gen + grub + initramfs in parallel)
code=000
for i in $(seq 1 60); do
  code=$(curl -k -s -o /dev/null -w '%{http_code}' --max-time 3 https://127.0.0.1:8443/api/system/status || echo 000)
  [ "$code" = "200" ] && break
  sleep 2
done

echo "--- service states ---"
for u in ffn-configd ffn-controld ffn-manager-v2 ffn-bmfw frr; do
  st=$(systemctl is-active "$u" 2>/dev/null || echo inactive)
  printf '  %-18s %s\n' "$u" "$st"
done
dp=$(systemctl is-active ffn-dpdk-fwd 2>/dev/null || echo inactive)
en=$(systemctl is-enabled ffn-dpdk-fwd 2>/dev/null || echo disabled)
printf '  %-18s %s (%s)\n' "ffn-dpdk-fwd" "$dp" "$en"

if [ "$code" = "200" ]; then
  ok "FFN SELFTEST: PASS — management plane up (WebUI/API https://:8443 -> 200). Login admin/admin."
else
  bad "FFN SELFTEST: WebUI/API not answering (http=$code) — check 'journalctl -u ffn-manager-v2'."
fi
echo "=== end selftest ==="
