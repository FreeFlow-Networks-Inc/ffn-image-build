/*
 * ffn_dpnet.h -- CP-side peer for the DP's PCIe-DMA virtual ethernet.
 *
 * WHAT THIS IS FOR
 * ----------------
 * On the PA-5220 the DP Octeon (CN78XX, 40 cores) is a PCIe endpoint of the CP
 * Octeon (CN73XX). Their "eth0" link is not a wire: it is a virtual ethernet
 * driven by the Octeon DMA engine on both sides. The vendor DP kernel boots all
 * 40 cores fine but then panics:
 *
 *      pci_dma_xmit: not initialized, returning        (repeated)
 *      VFS: Unable to mount root fs via NFS, trying floppy.
 *      Kernel panic - not syncing: VFS: Unable to mount root fs
 *
 * because nothing on the CP has brought up the far end of that link. FFN's CP
 * kernel cannot load the vendor's 3.10 module, so FFN needs its own host-role
 * peer. That is this driver.
 *
 * WHY A KERNEL MODULE AND NOT A USERSPACE DAEMON
 * ----------------------------------------------
 * ffn_pcnetd (the MP<->CP transport) is userspace because it only needs mmap of a
 * BAR. This one cannot be: the protocol is driven by MSI interrupts from the DP
 * and by the Octeon DPI DMA engine, and FFN's CP kernel has no VFIO to route MSI
 * to userspace. So the host role has to live in the kernel, as the vendor's does.
 *
 * EVIDENCE
 * --------
 * Everything below was recovered from the vendor DP kernel
 * (/opt/dpfs/boot/vmlinux.oct2-dp, which retains a 27541-entry .symtab; note that
 * the SDK `nm` reads it as empty -- use `readelf -sW`) with the SDK objdump.
 * pci_dma.c is compiled into that image TWICE, once per role:
 *
 *   host   copy: pci_dma_host_msi_interrupt   @ 0xffffffff804b7870
 *                pci_dma_init_module          @ 0xffffffff807b7dc0  (2784 bytes)
 *                pci_dma_xmit                 @ 0xffffffff804b6ed0
 *                update_rx_rings              @ 0xffffffff804b7598
 *                pci_dma_region1_alloc        @ 0xffffffff804b6d00
 *   target copy: pci_dma_target_msi_interrupt @ 0xffffffff804b9088
 *                pci_dma_xmit                 @ 0xffffffff804b8400  (1436 bytes)
 *                update_rx_rings              @ 0xffffffff804b8d70
 *
 * So the host-role implementation this driver must mirror is present in that
 * binary and can be read instruction by instruction. The same driver also serves
 * the x86<->CP link: its strings include "BROADWELL Host MSIX table:", which is
 * the Xeon-D host variant.
 *
 * VERIFIED host-role init order (calls made by pci_dma_init_module, host copy):
 *      cvmx_sysinfo_get
 *      printk("Loading pci_dma host [%d]")
 *      cvmx_dma_engine_initialize          <-- Octeon DPI DMA engine
 *      pci_get_device(0x177d, ...)         <-- 6013 decimal = Cavium vendor id
 *      alloc_etherdev_mqs
 *      memset / strcpy("eth%d")            <-- registers as eth%d
 *      register_netdev
 *      proc_create_data
 *      octeon_irq_get_block_domain
 *      irq_create_mapping ; request_threaded_irq ; __irq_set_affinity   (x2)
 * Both roles move payload with cvmx_dma_engine_transfer().
 *
 * VERIFIED misc:
 *   - the target's netdev init builds its MAC from bytes {0,?,0x0c,0x0d,...} and
 *     ORs 0x10 into one byte when the board type is 20020 = CVMX_BOARD_TYPE_GRYPHON.
 *   - TX/RX descriptors are 16 bytes; bit 1 of descriptor word +4 is an
 *     ownership/valid flag tested with `bbit0 v0,0x1`.
 *   - target priv-struct field offsets seen in pci_dma_xmit: 1664 (ring base),
 *     1704, 1856, 1872 (error/drop counters), 2032 (in-flight count), 2048
 *     (producer index), 2052 (consumer index), 2056 (per-slot byte flags), and a
 *     descriptor array at priv+1664+53*16.
 *
 * NOT YET RECOVERED -- and deliberately NOT guessed at
 * ---------------------------------------------------
 * The following are required for the DP to accept us, and are still unknown:
 *   (1) where the shared TX/RX rings physically live, and how the two sides
 *       exchange those addresses (candidates: the DP's BAR1 window, a cvmx
 *       bootmem named block, or a fixed DRAM offset);
 *   (2) the exact handshake that flips the DP's "initialized" predicate -- the
 *       string "not initialized, returning" is at vaddr 0xffffffff80699668 and is
 *       reached from a branch in the target pci_dma_xmit that still needs tracing;
 *   (3) the MSI vector layout: which of the two host IRQs is TX vs RX, and the
 *       address/data the DP expects us to write to signal it;
 *   (4) full descriptor field semantics beyond the valid bit.
 *
 * These are left as compile-time-absent rather than filled with plausible values
 * ON PURPOSE. Guessing a DMA target address would make the CP's DMA engine write
 * into unknown DP DRAM on a live chip; a driver that refuses to load is strictly
 * better than one that silently corrupts the far end. FFN_DPNET_PROTO_COMPLETE
 * gates the data path: until the four items above are filled in, the driver binds,
 * reports exactly what it knows, and stops.
 */

#ifndef FFN_DPNET_H
#define FFN_DPNET_H

/* The DP endpoint as FFN's CP kernel enumerates it. Confirmed live: the CP sees
 * the 40-core CN78XX at 0003:03:00.0, behind two PLX PEX8606 bridges. */
#define FFN_DPNET_PCI_VENDOR   0x177d   /* Cavium; the vendor driver passes 6013 */
#define FFN_DPNET_PCI_DEVICE   0x0095   /* observed device id of the DP endpoint */
#define FFN_DPNET_PCI_SLOT     "0003:03:00.0"

/* Board type the DP's own netdev init compares against (li v1,20020). */
#define FFN_DPNET_BOARD_GRYPHON 20020

/* Descriptor geometry recovered from both copies of pci_dma_xmit. */
#define FFN_DPNET_DESC_SIZE     16      /* bytes per descriptor */
#define FFN_DPNET_DESC_VALID_BIT 1      /* bit 1 of word at desc+4 */

/* Offsets into the peer's private structure, as read out of the target's
 * pci_dma_xmit. Kept here as documentation of the far end's bookkeeping; this
 * driver does not write them directly. */
#define FFN_DPNET_OFF_RING_BASE   1664
#define FFN_DPNET_OFF_ERR_COUNT   1704
#define FFN_DPNET_OFF_DROP_1      1856
#define FFN_DPNET_OFF_DROP_2      1872
#define FFN_DPNET_OFF_INFLIGHT    2032
#define FFN_DPNET_OFF_PROD_IDX    2048
#define FFN_DPNET_OFF_CONS_IDX    2052
#define FFN_DPNET_OFF_SLOT_FLAGS  2056
#define FFN_DPNET_DESC_ARRAY_OFF  (FFN_DPNET_OFF_RING_BASE + 53 * FFN_DPNET_DESC_SIZE)

/*
 * Set this only when items (1)-(4) in the header comment are filled in and the
 * constants below have been recovered rather than invented. While it is unset the
 * driver performs bind + discovery + reporting only, and never programs the DMA
 * engine.
 */
/* #define FFN_DPNET_PROTO_COMPLETE 1 */

#endif /* FFN_DPNET_H */
