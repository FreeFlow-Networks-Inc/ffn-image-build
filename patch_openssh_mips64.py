#!/usr/bin/env python3
"""Work around a gcc 13.4 ICE on mips64 that kills the openssh build.

    during RTL pass: zero_call_used_regs
    moduli.c:814:1: internal compiler error: in int_mode_for_mode,
                    at stor-layout.cc:407

openssh's configure probes -fzero-call-used-regs with a TRIVIAL function ("Trivial
function to help test for -fzero-call-used-regs"), which compiles fine, so it adds
-fzero-call-used-regs=used to CFLAGS -- and then real code (moduli.c) ICEs the
compiler.

Buildroot already models this class of failure as BR2_TOOLCHAIN_HAS_GCC_BUG_110934
and responds with --without-hardening, but that symbol is `default y if BR2_m68k`
only: the bug it cites is the m68k manifestation (change_address_1, emit-rtl.cc:2287).
Ours is the same RTL pass on mips64 with a different ICE site, so Buildroot does not
know to apply it. That is a genuine upstream gap.

We do NOT use --without-hardening, because it would also drop
-fstack-protector-strong, PIE and the FORTIFY additions from sshd -- a real security
reduction on a network daemon. Instead strip just the one flag that breaks the
compiler, leaving every other hardening measure in place.
"""
P = "/root/ffn-image-build/buildroot-2025.02.9/package/openssh/openssh.mk"
src = open(P).read()
open(P + ".bak-ffn", "w").write(src)

if "OPENSSH_DROP_ZERO_CALL_USED_REGS" in src:
    raise SystemExit("  already patched")

anchor = "OPENSSH_DEPENDENCIES = host-pkgconf zlib openssl"
if anchor not in src:
    raise SystemExit("  !! anchor not found; openssh.mk untouched")

block = """# FFN: gcc 13.4 ICEs on mips64 in the zero_call_used_regs RTL pass
# (moduli.c: internal compiler error: in int_mode_for_mode, at stor-layout.cc:407).
# openssh's configure probes the flag with a trivial function, which compiles, so it
# adds -fzero-call-used-regs=used and real code then breaks the compiler. Buildroot
# models this as BR2_TOOLCHAIN_HAS_GCC_BUG_110934 -> --without-hardening, but that
# symbol is scoped "default y if BR2_m68k" and cites the m68k ICE site, so it does not
# fire here. Strip only the offending flag: --without-hardening would also lose
# -fstack-protector-strong, PIE and FORTIFY on a network daemon.
ifneq ($(BR2_mips64)$(BR2_mips64el),)
define OPENSSH_DROP_ZERO_CALL_USED_REGS
\t$(SED) 's/-fzero-call-used-regs=used//g' $(@D)/configure
endef
OPENSSH_POST_PATCH_HOOKS += OPENSSH_DROP_ZERO_CALL_USED_REGS
endif

"""
open(P, "w").write(src.replace(anchor, block + anchor, 1))
print("  patched openssh.mk (backup .bak-ffn)")
