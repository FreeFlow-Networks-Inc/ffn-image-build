/*
 * ffn_dpagent -- control channel agent for the DP Octeon (CN7885).
 *
 * WHY THIS EXISTS
 * ---------------
 * The DP boots to userspace, but its console is its own ttyS0 and nothing on the
 * CP can read it (the kernel even reports "octeon_pci_console: Console not
 * created", so the bootloader never set up a PCI console descriptor). What the CP
 * *can* do is read and write DP DRAM: it is a PCIe host for the DP, and FFN
 * already drives that path (ffn_dpmem/ffn_dpsend). So the control channel is a
 * shared-memory mailbox in DP DRAM -- this agent serves it from the DP side, and
 * ffn_dpsh.py drives it from the CP.
 *
 * WHERE IT LIVES
 * --------------
 * FFN_DP_RING_BASE is 0x00400000. That is deliberate: from the DP's own boot log
 * Linux owns 0x800000-0xfa3000, 0x1070000-0x119f000, 0xdff00000+ and 0xf0001000+,
 * so everything below 0x800000 is outside the kernel's RAM map and will never be
 * allocated. 0x400000 also clears the two things that DO live down there -- the
 * bootloader mailbox at 0x6c000 and the device tree at 0x80000.
 * The kernel has CONFIG_DEVMEM=y and no CONFIG_STRICT_DEVMEM, so /dev/mem reaches
 * it. The initramfs has no /dev/mem node, so we create it.
 *
 * BYTE ORDER
 * ----------
 * This side is plain big-endian: it reads and writes the structure natively. The
 * CP's accesses arrive byte-reversed within each aligned 64-bit word (a property of
 * the BAR1 window, proven earlier), so ALL swapping is the CP's job. Keeping the
 * asymmetry on one side only is what makes both halves simple.
 *
 * SAFETY
 * ------
 * This runs as the DP's only userspace process, so it must never die: every step is
 * checked, a failed command is reported rather than fatal, and the poll loop has no
 * exit path. It executes commands with /bin/sh -c (busybox), capturing stdout and
 * stderr together.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/sysmacros.h>   /* makedev */
#include <stdint.h>

#define RING_BASE   0x00400000UL
#define RING_SIZE   0x10000UL          /* 64 KB */

#define OFF_MAGIC    0x0000
#define OFF_VERSION  0x0008
#define OFF_AGENT_UP 0x000c
#define OFF_CMD_SEQ  0x0010
#define OFF_CMD_LEN  0x0014
#define OFF_RSP_SEQ  0x0018
#define OFF_RSP_LEN  0x001c
#define OFF_RSP_STAT 0x0020
#define OFF_CMD      0x0100
#define OFF_RSP      0x1000

#define CMD_MAX      0x0e00            /* 3584 bytes of command */
#define RSP_MAX      0xf000            /* 61440 bytes of output  */

static const char MAGIC[8] = { 'F','F','N','D','P','S','H','1' };

static volatile unsigned char *ring;

/* The DP is big-endian, so these are plain loads/stores in network order. */
static uint32_t rd32(unsigned off)
{
	const volatile unsigned char *p = ring + off;
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	       ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void wr32(unsigned off, uint32_t v)
{
	volatile unsigned char *p = ring + off;
	p[0] = (v >> 24) & 0xff;
	p[1] = (v >> 16) & 0xff;
	p[2] = (v >> 8) & 0xff;
	p[3] = v & 0xff;
}

/* Run one command, capturing stdout+stderr. Returns the exit status. */
static int run_capture(const char *cmd, char *out, size_t outsz, size_t *outlen)
{
	int fds[2];
	pid_t pid;
	size_t used = 0;
	int status = -1;

	*outlen = 0;
	if (pipe(fds) != 0) {
		used = snprintf(out, outsz, "ffn_dpagent: pipe failed: %s\n",
				strerror(errno));
		*outlen = used;
		return -1;
	}

	pid = fork();
	if (pid < 0) {
		close(fds[0]);
		close(fds[1]);
		used = snprintf(out, outsz, "ffn_dpagent: fork failed: %s\n",
				strerror(errno));
		*outlen = used;
		return -1;
	}

	if (pid == 0) {
		close(fds[0]);
		dup2(fds[1], STDOUT_FILENO);
		dup2(fds[1], STDERR_FILENO);
		close(fds[1]);
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		/* only reached if exec failed */
		fprintf(stderr, "ffn_dpagent: exec /bin/sh failed: %s\n",
			strerror(errno));
		_exit(127);
	}

	close(fds[1]);
	for (;;) {
		ssize_t n;

		if (used >= outsz - 1)
			break;
		n = read(fds[0], out + used, outsz - 1 - used);
		if (n > 0)
			used += (size_t)n;
		else if (n == 0)
			break;
		else if (errno != EINTR)
			break;
	}
	close(fds[0]);
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
		;
	out[used] = 0;
	*outlen = used;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int main(void)
{
	int fd;
	uint32_t last_seq;
	char *cmd, *rsp;

	/* The initramfs ships no /dev/mem; make one. Ignore EEXIST. */
	if (mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1)) != 0 &&
	    errno != EEXIST)
		fprintf(stderr, "ffn_dpagent: mknod /dev/mem: %s\n",
			strerror(errno));

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "ffn_dpagent: open /dev/mem: %s\n",
			strerror(errno));
		return 1;
	}

	ring = mmap(NULL, RING_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
		    fd, (off_t)RING_BASE);
	if (ring == MAP_FAILED) {
		fprintf(stderr, "ffn_dpagent: mmap 0x%lx: %s\n",
			RING_BASE, strerror(errno));
		return 1;
	}

	cmd = malloc(CMD_MAX + 1);
	rsp = malloc(RSP_MAX + 1);
	if (!cmd || !rsp) {
		fprintf(stderr, "ffn_dpagent: out of memory\n");
		return 1;
	}

	/* Publish the header last-field-first so the CP never sees a half-set
	 * mailbox: zero the sequence numbers, then stamp the magic. */
	wr32(OFF_CMD_SEQ, 0);
	wr32(OFF_CMD_LEN, 0);
	wr32(OFF_RSP_SEQ, 0);
	wr32(OFF_RSP_LEN, 0);
	wr32(OFF_RSP_STAT, 0);
	wr32(OFF_VERSION, 1);
	wr32(OFF_AGENT_UP, 1);
	memcpy((void *)(ring + OFF_MAGIC), MAGIC, sizeof(MAGIC));

	printf("ffn_dpagent: serving at phys 0x%lx (%lu bytes)\n",
	       RING_BASE, RING_SIZE);
	fflush(stdout);

	last_seq = 0;
	for (;;) {
		uint32_t seq = rd32(OFF_CMD_SEQ);
		uint32_t len;
		size_t olen = 0;
		int rc;

		if (seq == last_seq) {
			usleep(50000);          /* 50 ms */
			continue;
		}

		len = rd32(OFF_CMD_LEN);
		if (len > CMD_MAX)
			len = CMD_MAX;
		memcpy(cmd, (const void *)(ring + OFF_CMD), len);
		cmd[len] = 0;

		rc = run_capture(cmd, rsp, RSP_MAX, &olen);
		if (olen > RSP_MAX)
			olen = RSP_MAX;
		memcpy((void *)(ring + OFF_RSP), rsp, olen);
		wr32(OFF_RSP_LEN, (uint32_t)olen);
		wr32(OFF_RSP_STAT, (uint32_t)rc);
		/* sequence LAST: it is what tells the CP the rest is valid */
		wr32(OFF_RSP_SEQ, seq);
		last_seq = seq;
	}
	return 0;
}
