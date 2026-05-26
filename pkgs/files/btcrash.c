/* btcrash - LD_PRELOAD crash tracer for bbnix on QNX/BB10.
 *
 * Caches the process memory map at startup (via /proc/self/as devctl - reading
 * its own process, always permitted, and unaffected by ASLR since it's the
 * live layout) and, on a fatal signal, prints the fault address, the faulting
 * PC/LR (from the signal ucontext) and the cached map, then re-raises the
 * default action. Offline: find the file-backed region whose [vaddr,vaddr+size)
 * contains PC, compute elf_addr = PC - vaddr + off, and addr2line it.
 */
#include <ucontext.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <devctl.h>
#include <sys/procfs.h>

#define MAXR 256
static struct { char name[160]; unsigned vaddr, off, size; } g_reg[MAXR];
static int g_n;

static void cache_memmap(void) {
	char path[64];
	snprintf(path, sizeof path, "/proc/%d/as", (int)getpid());
	int fd = open(path, O_RDONLY);
	if (fd < 0) return;

	int num = 0;
	if (devctl(fd, DCMD_PROC_MAPINFO, NULL, 0, &num) != EOK || num <= 0) { close(fd); return; }

	procfs_mapinfo *maps = malloc((size_t)num * sizeof *maps);
	size_t dbsz = sizeof(procfs_debuginfo) + PATH_MAX + 1;
	procfs_debuginfo *db = malloc(dbsz);
	if (!maps || !db) { free(maps); free(db); close(fd); return; }

	int got = num;
	if (devctl(fd, DCMD_PROC_MAPINFO, maps, (size_t)num * sizeof *maps, &got) == EOK) {
		for (int i = 0; i < got && g_n < MAXR; i++) {
			memset(db, 0, dbsz);
			db->vaddr = maps[i].vaddr;
			const char *name = "?";
			if (devctl(fd, DCMD_PROC_MAPDEBUG, db, dbsz, NULL) == EOK && db->path[0])
				name = db->path;
			strncpy(g_reg[g_n].name, name, sizeof g_reg[g_n].name - 1);
			g_reg[g_n].name[sizeof g_reg[g_n].name - 1] = '\0';
			g_reg[g_n].vaddr = (unsigned)maps[i].vaddr;
			g_reg[g_n].off   = (unsigned)maps[i].offset;
			g_reg[g_n].size  = (unsigned)maps[i].size;
			g_n++;
		}
	}
	free(db);
	free(maps);
	close(fd);
}

static void dump(int sig, siginfo_t *si, void *ucv) {
	char b[256];
	int n;
	ucontext_t *uc = (ucontext_t *)ucv;
	unsigned pc = 0, lr = 0, sp = 0;
	if (uc) {
		pc = uc->uc_mcontext.cpu.gpr[ARM_REG_PC];
		lr = uc->uc_mcontext.cpu.gpr[ARM_REG_LR];
		sp = uc->uc_mcontext.cpu.gpr[ARM_REG_SP];
	}
	void *fa = si ? si->si_addr : (void *)0;
	n = snprintf(b, sizeof b,
	             "\n=== btcrash: signal %d  fault_addr=%p  pc=0x%x lr=0x%x sp=0x%x  regions=%d ===\n",
	             sig, fa, pc, lr, sp, g_n);
	if (n > 0) write(STDERR_FILENO, b, (size_t)n);

	write(STDERR_FILENO, "--- memmap (name vaddr off size) ---\n", 37);
	for (int i = 0; i < g_n; i++) {
		n = snprintf(b, sizeof b, "%s v=0x%x off=0x%x sz=0x%x\n",
		             g_reg[i].name, g_reg[i].vaddr, g_reg[i].off, g_reg[i].size);
		if (n > 0) write(STDERR_FILENO, b, (size_t)n);
	}

	signal(sig, SIG_DFL);
	raise(sig);
}

__attribute__((constructor))
static void btcrash_install(void) {
	cache_memmap();
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = dump;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS,  &sa, NULL);
	sigaction(SIGILL,  &sa, NULL);
	sigaction(SIGFPE,  &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
}
