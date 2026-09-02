// SPDX-License-Identifier: GPL-2.0
/*
 * ffn_dpnet -- FFN's CP-side peer for the DP's PCIe-DMA virtual ethernet.
 *
 * FFN own code. See ffn_dpnet.h for the reverse-engineering evidence, the
 * verified host-role init order, and the four protocol items still outstanding.
 *
 * The structure mirrors the vendor host role deliberately: the DP's driver is the
 * other half of a fixed protocol, so we do not get to choose the shape.
 *
 *   cvmx_sysinfo_get -> cvmx_dma_engine_initialize -> pci_get_device(0x177d)
 *   -> alloc_etherdev_mqs -> register_netdev -> proc_create_data
 *   -> irq_create_mapping + request_threaded_irq (x2, with affinity)
 *
 * Until the shared-ring addresses, the init handshake, the MSI vector layout and
 * the descriptor semantics are recovered (FFN_DPNET_PROTO_COMPLETE), this driver
 * stops after discovery and reports what it found. That is deliberate: the data
 * path programs the CP's DMA engine with addresses in DP DRAM, and inventing
 * those would have the CP DMA into unknown memory on a live 40-core chip. A
 * module that declines to move packets is recoverable; one that scribbles on the
 * far end is not.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/pci.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/io.h>

#include "ffn_dpnet.h"

#define DRV_NAME "ffn_dpnet"

struct ffn_dpnet {
	struct pci_dev		*pdev;
	struct net_device	*ndev;
	resource_size_t		bar0_len;
	resource_size_t		bar1_len;
	int			irq_rx;
	int			irq_tx;
	bool			dma_ready;	/* DPI engine initialised */
	bool			proto_ready;	/* far-end handshake complete */
};

static struct ffn_dpnet *ffn_dp;

/* ------------------------------------------------------------------ netdev */

static int ffn_dpnet_open(struct net_device *ndev)
{
	struct ffn_dpnet *dp = netdev_priv(ndev);

	if (!dp->proto_ready) {
		netdev_warn(ndev,
			    "refusing to open: DP-side protocol not fully recovered "
			    "(see ffn_dpnet.h); not programming the DMA engine\n");
		return -ENODEV;
	}
	netif_start_queue(ndev);
	return 0;
}

static int ffn_dpnet_stop(struct net_device *ndev)
{
	netif_stop_queue(ndev);
	return 0;
}

static netdev_tx_t ffn_dpnet_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	/* The real path posts the frame to the shared TX ring, hands it to the DPI
	 * DMA engine (cvmx_dma_engine_transfer), then raises the DP's MSI. Both the
	 * ring address and the MSI are still unknown, so drop rather than guess --
	 * counted, so the gap shows up in ifconfig instead of being silent. */
	ndev->stats.tx_dropped++;
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

static const struct net_device_ops ffn_dpnet_netdev_ops = {
	.ndo_open	= ffn_dpnet_open,
	.ndo_stop	= ffn_dpnet_stop,
	.ndo_start_xmit	= ffn_dpnet_xmit,
};

/* --------------------------------------------------------------- interrupts */

/* The vendor host role takes two threaded IRQs and pins their affinity. Which is
 * TX-completion and which is RX-available is not established yet, so for now
 * both land here and are only acknowledged. */
static irqreturn_t ffn_dpnet_isr(int irq, void *data)
{
	struct ffn_dpnet *dp = data;

	if (!dp || !dp->proto_ready)
		return IRQ_HANDLED;

	return IRQ_HANDLED;
}

/* --------------------------------------------------------------------- proc */

static int ffn_dpnet_show(struct seq_file *m, void *v)
{
	struct ffn_dpnet *dp = ffn_dp;

	if (!dp || !dp->pdev) {
		seq_puts(m, "ffn_dpnet: not bound\n");
		return 0;
	}
	seq_printf(m, "DP endpoint      : %s\n", pci_name(dp->pdev));
	seq_printf(m, "vendor:device    : %04x:%04x\n",
		   dp->pdev->vendor, dp->pdev->device);
	seq_printf(m, "BAR0 (CSR)       : %llu bytes\n",
		   (unsigned long long)dp->bar0_len);
	seq_printf(m, "BAR1 (DRAM win)  : %llu bytes\n",
		   (unsigned long long)dp->bar1_len);
	seq_printf(m, "DPI DMA engine   : %s\n",
		   dp->dma_ready ? "initialised" : "NOT AVAILABLE in this kernel");
	seq_printf(m, "protocol         : %s\n",
		   dp->proto_ready ? "complete" : "INCOMPLETE - data path disabled");
	seq_puts(m, "\nOutstanding (see ffn_dpnet.h):\n"
		    "  1. shared ring location + how the two sides exchange it\n"
		    "  2. the handshake that clears the DP's not-initialized state\n"
		    "  3. MSI vector layout (which IRQ is TX vs RX; how to signal the DP)\n"
		    "  4. descriptor field semantics beyond the valid bit\n");
	return 0;
}

static int ffn_dpnet_proc_open(struct inode *inode, struct file *file)
{
	return single_open(file, ffn_dpnet_show, NULL);
}

static const struct file_operations ffn_dpnet_proc_fops = {
	.owner		= THIS_MODULE,
	.open		= ffn_dpnet_proc_open,
	.read		= seq_read,
	.llseek		= seq_lseek,
	.release	= single_release,
};

/* --------------------------------------------------------------------- bind */

static int ffn_dpnet_bind(struct ffn_dpnet *dp)
{
	struct pci_dev *pdev;

	/* The vendor walks for vendor 0x177d alone; we match the device id too so we
	 * cannot pick up the CP's own PCIe ports by accident. */
	pdev = pci_get_device(FFN_DPNET_PCI_VENDOR, FFN_DPNET_PCI_DEVICE, NULL);
	if (!pdev) {
		pr_err(DRV_NAME ": no Cavium %04x:%04x endpoint; is the DP present?\n",
		       FFN_DPNET_PCI_VENDOR, FFN_DPNET_PCI_DEVICE);
		return -ENODEV;
	}

	/* Memory-Space-Enable matters here. Nothing else binds the DP, so Linux
	 * never runs pci_enable_bridge() on the two PLX bridges above it and every
	 * read returns all-ones. pci_enable_device() walks up and fixes them. This
	 * was the real cause of what first looked like a TWSI/I2C hang during DP
	 * bring-up, so it is not an incidental call. */
	if (pci_enable_device(pdev)) {
		pr_err(DRV_NAME ": pci_enable_device failed for %s\n", pci_name(pdev));
		pci_dev_put(pdev);
		return -ENODEV;
	}
	pci_set_master(pdev);

	dp->pdev = pdev;
	dp->bar0_len = pci_resource_len(pdev, 0);
	dp->bar1_len = pci_resource_len(pdev, 2);	/* resource2 == Octeon BAR1 */

	pr_info(DRV_NAME ": bound %s (%04x:%04x) BAR0 %llu, BAR1 %llu bytes\n",
		pci_name(pdev), pdev->vendor, pdev->device,
		(unsigned long long)dp->bar0_len,
		(unsigned long long)dp->bar1_len);
	return 0;
}

static void ffn_dpnet_unbind(struct ffn_dpnet *dp)
{
	if (dp->pdev) {
		pci_disable_device(dp->pdev);
		pci_dev_put(dp->pdev);
		dp->pdev = NULL;
	}
}

/* --------------------------------------------------------------------- init */

static int __init ffn_dpnet_init(void)
{
	struct net_device *ndev;
	struct ffn_dpnet *dp;
	int rc;

	pr_info(DRV_NAME ": loading CP-side peer for the DP PCIe-DMA ethernet\n");

	ndev = alloc_etherdev(sizeof(*dp));
	if (!ndev)
		return -ENOMEM;
	dp = netdev_priv(ndev);
	dp->ndev = ndev;
	ffn_dp = dp;

	rc = ffn_dpnet_bind(dp);
	if (rc)
		goto err_free;

	/*
	 * The vendor host role calls cvmx_dma_engine_initialize() at this point, and
	 * both sides move payload with cvmx_dma_engine_transfer(). FFN's CP kernel
	 * exports NEITHER -- there are no cvmx_dma_engine_* symbols in its vmlinux
	 * at all, though the SDK ships
	 * arch/mips/include/asm/octeon/cvmx-dma-engine.h. So the CP kernel has to be
	 * rebuilt with the DPI engine enabled before this driver can have a data
	 * path. Flagged loudly rather than faked.
	 */
	dp->dma_ready = false;
	pr_warn(DRV_NAME ": Octeon DPI DMA engine unavailable in this kernel "
			 "(no cvmx_dma_engine_* symbols); data path stays disabled\n");

	dp->proto_ready = false;

	ndev->netdev_ops = &ffn_dpnet_netdev_ops;
	/* The vendor registers as eth%d; dp%d is clearer on the CP, whose eth0 is a
	 * real port. */
	strcpy(ndev->name, "dp%d");
	eth_hw_addr_random(ndev);

	rc = register_netdev(ndev);
	if (rc) {
		pr_err(DRV_NAME ": register_netdev failed: %d\n", rc);
		goto err_unbind;
	}

	proc_create_data(DRV_NAME, 0444, NULL, &ffn_dpnet_proc_fops, NULL);

	pr_info(DRV_NAME ": registered %s; discovery only -- /proc/%s lists what "
			 "remains before the DP will accept us\n",
		ndev->name, DRV_NAME);
	return 0;

err_unbind:
	ffn_dpnet_unbind(dp);
err_free:
	ffn_dp = NULL;
	free_netdev(ndev);
	return rc;
}

static void __exit ffn_dpnet_exit(void)
{
	struct ffn_dpnet *dp = ffn_dp;

	remove_proc_entry(DRV_NAME, NULL);
	if (dp && dp->ndev) {
		unregister_netdev(dp->ndev);
		ffn_dpnet_unbind(dp);
		free_netdev(dp->ndev);
	}
	ffn_dp = NULL;
	pr_info(DRV_NAME ": unloaded\n");
}

module_init(ffn_dpnet_init);
module_exit(ffn_dpnet_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("FFN");
MODULE_DESCRIPTION("CP-side peer for the DP PCIe-DMA virtual ethernet (PA-5220)");
