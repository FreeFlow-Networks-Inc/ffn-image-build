# ffn-image-build

The FFN NGFW appliance image and installer build system. Registered as a
submodule of [FFN-NGFW](https://github.com/FreeFlow-Networks-Inc/FFN-NGFW).

Produces, from a Debian/Ubuntu host:

* `out/<ver>-rootfs.tar.zst` and `<ver>-recovery.tar.zst` — the two root
  filesystems, main and recovery/maintenance
* `out/<ver>.qcow2` — a bootable virtual disk (convert to raw for a USB stick)
* `out/install-to-disk.sh` — the bare-metal installer

## Quick start

    sudo ./build.sh                                  # harvest from this live box
    FFN_PRESEED=1 sudo -E ./build.sh                 # use a pre-staged payload
    FFN_SERIAL_BAUD=9600 FFN_PRESEED=1 sudo -E ./build.sh   # PA-3200 / PA-5200

**Pass `FFN_SERIAL_BAUD=9600` for appliance chassis.** It defaults to 115200,
while the provisioned rootfs hardcodes `console=ttyS0,9600`. Build without it
and the recovery GRUB entry is written at 115200 while the main entry is 9600 —
recovery becomes unreachable on the only console the box has.

## Installing to disk

`install-to-disk.sh` is interactive and asks three things: which disk(s) hold the
OS, which hold `/opt/ffn-logs`, and RAID 1 or RAID 0 for the log volume. Disks
may also be given positionally (`./install-to-disk.sh /dev/sdX [/dev/sdY]`).

**RAID 0 is offered for logs but not for the OS**, and not merely on taste:

* a stripe has no redundancy, on the volume whose entire job is surviving a disk
  death;
* the OS mirror uses `--metadata=1.0` deliberately, which puts the RAID
  superblock at the **end** of the member so the ext4 filesystem still begins at
  offset 0. That is what lets GRUB, blkid and e2fsck read a mirror member as an
  ordinary partition with no RAID support present. A stripe has no equivalent —
  no single member holds a readable filesystem — so early boot would depend on
  GRUB assembling the array before it can read `/boot`.

The installer refuses to offer the disk the live environment is running from, and
derives identical partition sizes from the **smaller** disk when mirroring, since
reclaimed chassis usually hold two different SSD models that differ by a few MB.

## Layout

| path | what |
|---|---|
| `build.sh` | the pipeline: host tooling → payload → debootstrap → provision → image |
| `provision.sh` | runs inside the chroot; authors `/etc/default/grub`, fstab, units |
| `config.sh`, `payload/config.sh` | package sets, image geometry, labels, baud |
| `install-to-disk.sh` | interactive bare-metal installer |
| `verify-image.sh` | post-build assertions |
| `payload/units/` | the systemd units the appliance runs |
| `patches/` | image patches |
| `profiles/` | per-model dataplane port maps |
| `dprootfs/` | Buildroot config for the OCTEON planes' userland |
| `ffn-logvol.sh` | discovers the chassis log RAID at boot and mounts it |
| `ffn-hwtune.sh` | recomputes hugepages/isolcpus on first boot from real core count |

## Buildroot: the OCTEON planes' userland

`dprootfs/ffn_octeon_defconfig` builds a mips64 **big-endian** octeon3 rootfs for
the CP and DP. Reproduce with Buildroot 2025.02.9:

    make BR2_DEFCONFIG=$PWD/dprootfs/ffn_octeon_defconfig defconfig
    FORCE_UNSAFE_CONFIGURE=1 make

`FORCE_UNSAFE_CONFIGURE=1` is needed only because GNU tar's configure refuses to
run as root; Buildroot itself discourages root builds, so prefer a normal user
where the paths allow it.

Four options in that defconfig exist because their absence broke something real:

* `BR2_PACKAGE_PYTHON3_ZLIB` — pip is distributed as a wheel, i.e. a zip, and
  `zipimport` cannot decompress one without zlib. Without it
  `python3 -m ensurepip` fails with `No module named 'zlib'` even though
  `libz.so` is present, because only the CPython binding was missing. This is
  what makes a package manager possible on this architecture at all.
* `BR2_PACKAGE_PYTHON3_BZIP2`, `_XZ` — the same omission class.
* the busybox fragment enabling `CONFIG_TELNETD` — Buildroot's stock busybox
  config ships `# CONFIG_TELNETD is not set`, so `ffn-cpshd` could not serve a
  shell on a rootfs built without it.

`BR2_KERNEL_HEADERS_5_4` with `BR2_PACKAGE_GLIBC_KERNEL_COMPAT` is deliberate:
the DP runs 4.9 and Buildroot 2025.02 offers no 4.9 headers, so glibc is told to
stay compatible with an older kernel. One rootfs serves both planes, so do not
bump headers to suit the CP without checking the DP.

## Known gaps

* **The payload is harvested, not built.** `build.sh` tars `/opt/ffn-ngfw-v2`
  off the live box it runs on. From a clean clone there is no live box, so
  `FFN_PRESEED=1` needs a payload assembled from repo content — the FFN software
  is published in FFN-NGFW's `opt/`. This harvest is also how a build host's own
  configuration leaks into appliance images.
* **`build.sh` here and `FFN-NGFW/image/build.sh` have diverged** (282 vs 317
  lines). `image/` additionally carries `PUBLISH-POLICY`,
  `ffn-publish-check.py`, `ffn-installer.sh` and `ffn-installer.service`. One of
  the two needs to become authoritative; two build scripts is a trap.
