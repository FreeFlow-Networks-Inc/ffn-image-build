#!/usr/bin/env bash
# post-ubuntu-install.sh -- turn a clean Ubuntu install on a PA-5220 into an
# FFN NGFW appliance, from the published GitHub sources.
#
#   sudo ./post-ubuntu-install.sh --dry-run     # print every action, change nothing
#   sudo ./post-ubuntu-install.sh               # do it
#   sudo ./post-ubuntu-install.sh --skip-apt    # packages already installed
#
# Run it on the box itself, after Ubuntu is installed and networking works.
# It is idempotent: re-running is safe and skips what is already done.
#
# HONESTY ABOUT COVERAGE: this has not been run end to end on a freshly
# installed PA-5220, because there wasn't one to try it on. Every individual
# step is taken from a working appliance or from provision.sh, but the
# composition is untested. Use --dry-run first and read the output. Anything it
# cannot do it reports loudly rather than pretending.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   * It does not partition or install to disk. That is install-to-disk.sh, run
#     from a live USB. This script provisions an already-running Ubuntu.
#   * It does not touch the OCTEON planes. Bringing the control plane up on
#     6.18 is platform/pa5200/octeon/cp-6.18/ and needs the CP kernel built
#     first; see that README.
#   * It does not change the serial baud rate. The chassis console is 9600 and
#     changing it needs BIOS/BMC, GRUB, the kernel and the operator's terminal
#     to agree -- get one wrong on a headless box and you lose the console you
#     would use to fix it.
set -uo pipefail

REPO_ORG="https://github.com/FreeFlow-Networks-Inc"
SRC="${FFN_SRC:-/usr/local/src/FFN-NGFW}"
DEST="${FFN_DEST:-/opt/ffn-ngfw-v2}"
BAUD="${FFN_SERIAL_BAUD:-9600}"      # PA-3200/PA-5200 chassis console
DRY=0
SKIP_APT=0

for a in "$@"; do
	case "$a" in
		--dry-run) DRY=1 ;;
		--skip-apt) SKIP_APT=1 ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "unknown option: $a" >&2; exit 2 ;;
	esac
done

# ------------------------------------------------------------------ helpers --
C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HDR=$'\033[1;35m'; C_0=$'\033[0m'
step(){ printf '\n%s== %s ==%s\n' "$C_HDR" "$*" "$C_0"; }
ok(){   printf '  %sok%s   %s\n' "$C_OK" "$C_0" "$*"; }
warn(){ printf '  %swarn%s %s\n' "$C_WARN" "$C_0" "$*"; }
die(){  printf '  %sERROR%s %s\n' "$C_ERR" "$C_0" "$*" >&2; exit 1; }
run(){
	if [ "$DRY" = 1 ]; then printf '  would: %s\n' "$*"; return 0; fi
	"$@"
}
# For shell snippets that need redirection/pipes, which run() cannot take.
runsh(){
	if [ "$DRY" = 1 ]; then printf '  would: sh -c %s\n' "$1"; return 0; fi
	sh -c "$1"
}

[ "$DRY" = 1 ] && printf '%s*** DRY RUN -- nothing will be changed ***%s\n' "$C_WARN" "$C_0"

# ------------------------------------------------------------------ 1. preflight
step "1. preflight"
[ "$(id -u)" = 0 ] || die "run as root (sudo $0)"

. /etc/os-release 2>/dev/null || die "cannot read /etc/os-release"
ok "OS: ${PRETTY_NAME:-unknown}"
case "${VERSION_CODENAME:-}" in
	jammy) ok "codename jammy -- what the image build targets" ;;
	noble|focal) warn "codename ${VERSION_CODENAME}: package names may differ from the jammy set" ;;
	*) warn "unrecognised codename '${VERSION_CODENAME:-?}' -- proceeding, but package names are untested here" ;;
esac

# Chassis identification. The PA-5220's board is an Insyde "Grangeville"; its
# firmware also reports UEFI support even though the appliance boots BIOS/CSM.
if command -v dmidecode >/dev/null 2>&1; then
	VEND=$(dmidecode -s bios-vendor 2>/dev/null | head -1)
	BOARD=$(dmidecode -s system-product-name 2>/dev/null | head -1)
	ok "firmware: ${VEND:-?} / board: ${BOARD:-?}"
	case "$BOARD" in
		*Grangeville*) ok "Grangeville board -- PA-5200 family as expected" ;;
		*) warn "board is not Grangeville. This script assumes a PA-5200 chassis:" ;;
	esac
	[ -d /sys/firmware/efi ] && warn "booted UEFI. The appliance is BIOS/CSM; GRUB settings below assume i386-pc" \
	                         || ok "booted BIOS/CSM, as the appliance expects"
else
	warn "dmidecode absent -- cannot confirm this is a PA-5200 chassis"
fi

# The two internal 2 TB drives carry PAN-OS's Log volume on a reclaimed box.
# ffn-logvol.sh DISCOVERS that array at boot rather than baking a UUID in, so
# just report what is visible.
if command -v lsblk >/dev/null 2>&1; then
	NBIG=$(lsblk -dno NAME,SIZE 2>/dev/null | awk '$2 ~ /T$/ {n++} END {print n+0}')
	ok "disks: $(lsblk -dno NAME | tr '\n' ' ')(${NBIG} multi-TB, candidates for the log volume)"
fi

ping -c1 -W3 github.com >/dev/null 2>&1 && ok "github.com reachable" \
	|| die "no route to github.com -- this script clones from there"

# ------------------------------------------------------------------ 2. packages
step "2. packages"
if [ "$SKIP_APT" = 1 ]; then
	warn "--skip-apt given, not touching apt"
else
	# Package sets come from config.sh so there is exactly one list, shared with
	# the image build. Sourced in a subshell to avoid leaking its other vars.
	HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
	PKGCFG=""
	for c in "$HERE/payload/config.sh" "$HERE/config.sh"; do [ -r "$c" ] && PKGCFG="$c" && break; done
	if [ -n "$PKGCFG" ]; then
		# shellcheck disable=SC1090
		PKGS=$( set -a; . "$PKGCFG" >/dev/null 2>&1; printf '%s %s %s %s %s %s' \
			"${PKGS_BASE:-}" "${PKGS_STORAGE:-}" "${PKGS_NET:-}" "${PKGS_BUILD:-}" "${PKGS_PY:-}" "${PKGS_BOOT:-}" )
		ok "package list from $(basename "$PKGCFG"): $(echo "$PKGS" | wc -w) packages"
		# A '#' inside a quoted, backslash-continued PKGS_* assignment is literal
		# text, not a comment, and every word of it reaches apt as a package
		# name. That broke the image build for a week. Refuse rather than repeat it.
		case " $PKGS " in *" # "*|*"#"*) die "package list contains a '#' -- a comment leaked into a PKGS_* assignment in $PKGCFG" ;; esac
	else
		warn "no config.sh found next to this script; using a minimal fallback set"
		PKGS="git build-essential python3 python3-venv python3-dev mdadm nftables \
		      openssh-server ca-certificates curl jq pciutils ethtool lldpd \
		      initramfs-tools grub-pc-bin grub-common nfs-common zstd"
	fi
	run apt-get update -qq
	# shellcheck disable=SC2086
	run apt-get install -y --no-install-recommends $PKGS
	ok "packages installed"
fi

# ------------------------------------------------------------------ 3. serial console
step "3. serial console and GRUB (headless appliance: this IS the console)"
G=/etc/default/grub
[ -f "$G" ] || die "$G missing -- is grub installed? (PKGS_BOOT carries grub-pc-bin)"
[ "$DRY" = 1 ] || cp -a "$G" "${G}.bak-$(date +%Y%m%d-%H%M%S)"

# Written the way provision.sh writes it, and for the same reasons:
#  * GRUB_DEFAULT must be 'saved': ffn_updated.py REFUSES to arm an A/B switch
#    otherwise, because grub-reboot's one-shot is ignored unless it is 'saved',
#    which would let a bad image become permanent. SAVEDEFAULT=false stops a
#    normal boot rewriting saved_entry and making a one-shot sticky.
#  * GRUB_TERMINAL sets input AND output, so GRUB renders every menu twice and
#    the serial copy paints row by row -- 960 B/s at 9600 is ~83 ms per row.
#    Split it; keep input on both so a USB keyboard still works.
#  * TIMEOUT_STYLE unset defaults to 'menu', repainting the whole menu on every
#    tick. countdown prints one line per second; the menu is one keypress away.
#  * 'quiet' is deliberately absent: no video on this chassis, so serial is the
#    only boot progress there is, and verify-image.sh checks for exactly that.
runsh "cat > $G <<'EOF'
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=countdown
GRUB_DISTRIBUTOR=\"FFN NGFW\"
GRUB_CMDLINE_LINUX_DEFAULT=\"intel_iommu=on iommu=pt transparent_hugepage=never console=tty0 console=ttyS0,${BAUD}n8\"
GRUB_CMDLINE_LINUX=\"\"
GRUB_TERMINAL_INPUT=\"console serial\"
GRUB_TERMINAL_OUTPUT=\"serial\"
GRUB_SERIAL_COMMAND=\"serial --speed=${BAUD} --unit=0\"
GRUB_DISABLE_OS_PROBER=true
EOF"
ok "wrote $G (baud ${BAUD}, single terminal output, countdown, A/B-armable)"
# Hugepages and CPU isolation are NOT set here. They are hardware-specific --
# 3971 hugepages and isolcpus=8-15 suit this chassis and would break a smaller
# CPU -- so ffn-hwtune.sh recomputes them on first boot from the real core count.
warn "hugepages/isolcpus not set here; ffn-hwtune.sh derives them on first boot"
run update-grub
runsh "mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d"
runsh "printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty -o \"-p -- \\\\\\\\u\" --keep-baud ${BAUD} --noclear ttyS0 \$TERM\n' > /etc/systemd/system/serial-getty@ttyS0.service.d/baud.conf"
run systemctl enable "serial-getty@ttyS0.service"
ok "serial getty on ttyS0 at ${BAUD}"

# ------------------------------------------------------------------ 4. sources
step "4. clone FFN-NGFW and the submodules"
run mkdir -p "$(dirname "$SRC")"
if [ -d "$SRC/.git" ]; then
	ok "$SRC already a clone; fetching"
	run git -C "$SRC" fetch --quiet origin
	run git -C "$SRC" pull --quiet --ff-only
else
	run git clone --quiet "$REPO_ORG/FFN-NGFW.git" "$SRC"
fi

# THE TRAP: the submodules are registered with `update = none`, so `git clone`
# -- INCLUDING --recursive -- skips them and leaves empty directories, which
# reads as a broken repo. --checkout is required. Verified below, because a
# silent skip here is the single most likely way this script appears to work
# and produces nothing.
for sm in platform/pa5200 image-build; do
	run git -C "$SRC" submodule update --init --checkout "$sm"
	if [ "$DRY" = 0 ]; then
		if [ -z "$(ls -A "$SRC/$sm" 2>/dev/null)" ]; then
			die "$sm is EMPTY after --checkout. Without --checkout git prints 'Skipping submodule' and leaves nothing; if you see this even WITH it, check .gitmodules"
		fi
		ok "$sm checked out ($(find "$SRC/$sm" -type f | wc -l) files)"
	fi
done
# platform/vu9p is the FPGA gateware: private, proprietary, and not needed on a
# PA-5220. Left alone deliberately.
ok "platform/vu9p skipped (private FPGA gateware, not used on a PA-5220)"

# ------------------------------------------------------------------ 5. deploy
step "5. deploy the management plane to $DEST"
IB="$SRC/image-build"
run mkdir -p "$DEST"
# FFN's Python management plane lives in the repo's opt/ directory.
if [ -d "$SRC/opt" ]; then
	run rsync -a --exclude=venv --exclude=__pycache__ "$SRC/opt/" "$DEST/"
	ok "management plane deployed from $SRC/opt"
else
	die "$SRC/opt missing -- expected the management plane there"
fi
for d in dataplanes dpdk static tools examples; do
	[ -d "$SRC/$d" ] && run rsync -a "$SRC/$d" "$DEST/" && ok "copied $d"
done
# The platform submodule carries the OCTEON bring-up and both PCIe transports.
[ -d "$SRC/platform/pa5200" ] && run rsync -a "$SRC/platform/pa5200/" "$DEST/" \
	&& ok "platform/pa5200 overlaid (OCTEON bring-up, PCIe transports, host tooling)"

step "6. config, units and CLI"
# These live in the image-build payload rather than the main repo.
if [ -s "$IB/payload/etc-ffn-ngfw.tgz" ]; then
	run mkdir -p /etc/ffn-ngfw
	run tar xzf "$IB/payload/etc-ffn-ngfw.tgz" -C /
	ok "/etc/ffn-ngfw seeded"
else
	warn "$IB/payload/etc-ffn-ngfw.tgz absent -- /etc/ffn-ngfw not seeded"
fi
runsh "echo ${BAUD} > /etc/ffn-ngfw/serial-baud" && ok "recorded serial baud ${BAUD} (ffn-hwtune reads this)"
if [ -s "$IB/payload/ffn-cli" ]; then
	run install -m755 "$IB/payload/ffn-cli" /usr/local/bin/ffn-cli && ok "ffn-cli installed"
else
	warn "ffn-cli not found in the payload"
fi
if [ -d "$IB/payload/units" ] && [ -n "$(ls -A "$IB/payload/units" 2>/dev/null)" ]; then
	run cp -a "$IB/payload/units/." /etc/systemd/system/
	run systemctl daemon-reload
	ok "systemd units installed ($(ls "$IB/payload/units" | wc -l) entries)"
else
	warn "no units in $IB/payload/units -- services will not be enabled"
fi
for s in "$IB/ffn-logvol.sh" "$IB/ffn-hwtune.sh" "$IB/ffn-firstboot.sh" "$IB/ffn-selftest.sh"; do
	[ -r "$s" ] && run install -m755 "$s" /usr/local/sbin/ && ok "installed $(basename "$s")"
done
[ -r "$IB/payload/99-ffn-vendor.rules" ] && run install -m644 "$IB/payload/99-ffn-vendor.rules" /etc/udev/rules.d/ \
	&& ok "vendor udev rules installed"

step "7. python environment"
if [ -r "$SRC/requirements.txt" ]; then
	run python3 -m venv "$DEST/venv"
	run "$DEST/venv/bin/pip" install --quiet --upgrade pip
	run "$DEST/venv/bin/pip" install --quiet -r "$SRC/requirements.txt"
	ok "venv built from requirements.txt"
else
	warn "no requirements.txt -- skipping venv"
fi

step "8. enable services"
# Same order and set as provision.sh: sysd first (the state bus others publish
# to), watchdogd early so a chassis watchdog cannot reset us mid-boot, satd
# stays inert unless /etc/ffn-ngfw/satellite.json enables it.
for u in ffn-sysd ffn-watchdogd ffn-satd ffn-configd ffn-controld ffn-manager-v2 \
         ffn-bmfw ffn-dpdk-fwd ffn-license-monitor.timer ffn-sigdb-update.timer; do
	if [ -e "/etc/systemd/system/$u" ] || [ -e "/etc/systemd/system/${u}.service" ]; then
		run systemctl enable "$u" && ok "enabled $u"
	else
		warn "skip $u (unit absent)"
	fi
done

step "done"
cat <<'EOT'
  Next:
    ffn-cli status                     management plane state
    systemctl --failed                 anything that did not come up
    cat /proc/mdstat                   the chassis log RAID, if ffn-logvol found one
    journalctl -u ffn-manager-v2 -n50  the management plane's own log

  Reboot to pick up GRUB, the serial console and ffn-hwtune's first-boot tuning.

  NOT done by this script, deliberately:
    * OCTEON control plane on 6.18 -- see platform/pa5200/octeon/cp-6.18/README.md
    * disk partitioning/RAID       -- image-build/install-to-disk.sh from a live USB
    * serial baud changes          -- BIOS/BMC, GRUB, kernel and your terminal
                                      must agree; getting one wrong on a headless
                                      box costs you the console
EOT
