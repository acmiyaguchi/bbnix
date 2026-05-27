/* sh-launcher - generic ELF trampoline for shell-script tools in the bbnix bundle.
 *
 * The BB10 packaging path destroys a shell script's execute bit: the native
 * packager strips +x from directory assets, and the on-device installer re-adds
 * +x only to files with ELF magic. So a `#!/bin/sh` launcher can never be run
 * directly under the read-only app/native image. This trampoline is that ELF:
 * the installer grants it +x, and it execs `/bin/sh` on the real shell logic,
 * which lives as a non-executable sidecar (sh reads it as data - no +x needed).
 *
 * Convention: an ELF installed as bin/<tool> execs <root>/libexec/<tool>. It
 * resolves its own location from argv[0] (mirroring the script's own $0 /
 * `command -v` logic) and hands the bin dir to the script via BBNIX_BINDIR so
 * the script resolves the bundle root deterministically regardless of where the
 * sidecar sits. Dynamically linked against the device libc; no extra libs, so
 * it runs before any LD_LIBRARY_PATH is set.
 */
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>
#include <limits.h>

int main(int argc, char **argv)
{
	const char *arg0 = (argc > 0 && argv[0]) ? argv[0] : "sh-launcher";
	char self[PATH_MAX];

	/* Resolve our own path. If argv[0] has a slash it is a path (the device
	 * always invokes the bundle launcher by path); otherwise search PATH for an
	 * executable match, same as the script's `command -v` fallback. */
	if (strchr(arg0, '/')) {
		if (strlen(arg0) >= sizeof(self)) {
			fprintf(stderr, "%s: path too long\n", arg0);
			_exit(127);
		}
		strcpy(self, arg0);
	} else {
		const char *path = getenv("PATH");
		int found = 0;
		if (path) {
			const char dot = '.';
			const char *p = path;
			for (;;) {
				const char *colon = strchr(p, ':');
				size_t dlen = colon ? (size_t)(colon - p) : strlen(p);
				const char *dir = p;
				/* An empty component (leading/trailing/`::`) means ".". */
				if (dlen == 0) { dir = &dot; dlen = 1; }
				if (dlen + 1 + strlen(arg0) + 1 <= sizeof(self)) {
					memcpy(self, dir, dlen);
					self[dlen] = '/';
					strcpy(self + dlen + 1, arg0);
					if (access(self, X_OK) == 0) { found = 1; break; }
				}
				if (!colon) break;
				p = colon + 1;
			}
		}
		if (!found) {
			fprintf(stderr, "%s: cannot locate self on PATH\n", arg0);
			_exit(127);
		}
	}

	/* Capture the invoked basename BEFORE canonicalizing. As a generic
	 * trampoline this may be installed as a symlink (e.g. bin/mosh ->
	 * sh-launcher); we must exec libexec/<invoked-name>, not libexec/<target>.
	 * (dirname/basename clobber their argument, so work on copies.) */
	char bbuf[PATH_MAX], base[PATH_MAX];
	strcpy(bbuf, self);
	strncpy(base, basename(bbuf), sizeof(base) - 1);
	base[sizeof(base) - 1] = '\0';

	/* Canonicalize for the directory only (resolves a symlinked bin/<tool> and
	 * any ".."); tolerate failure by keeping self as resolved above. */
	char canon[PATH_MAX];
	if (realpath(self, canon) && strlen(canon) < sizeof(self))
		strcpy(self, canon);

	char dbuf[PATH_MAX];
	strcpy(dbuf, self);
	const char *bindir = dirname(dbuf);

	/* Sidecar lives at <bindir>/../libexec/<base>; let sh resolve the "..". */
	char sidecar[PATH_MAX];
	if (snprintf(sidecar, sizeof(sidecar), "%s/../libexec/%s", bindir, base)
	    >= (int)sizeof(sidecar)) {
		fprintf(stderr, "%s: sidecar path too long\n", arg0);
		_exit(127);
	}

	/* Hand the real bin dir to the script so it resolves the bundle root. */
	setenv("BBNIX_BINDIR", bindir, 1);

	/* exec /bin/sh <sidecar> <original args...>. */
	char **shargv = malloc((size_t)(argc + 2) * sizeof(char *));
	if (!shargv) { perror("malloc"); _exit(127); }
	shargv[0] = "/bin/sh";
	shargv[1] = sidecar;
	for (int i = 1; i < argc; i++)
		shargv[i + 1] = argv[i];
	shargv[argc + 1] = NULL;

	execv("/bin/sh", shargv);
	perror("sh-launcher: exec /bin/sh");
	_exit(127);
}
