# AGENTS.md

Engineering detail for bbnix: per-package build notes, the build sequence,
validation, deploy recipes, and layout. The high-level overview is in
[`README.md`](README.md).

## Layout

```
flake.nix          # devShell + package wiring (Model A sysroot by default)
toolchain/         # binutils, gcc recipes (+ files/, patches/)
pkgs/              # userland recipes: zlib, openssl, openssh, ncurses, mosh,
                   #   protobuf (+ protobuf-host), libevent, tmux, zsh, qnx-compat
                   #   (then busybox)
  qnx-common.nix   # shared cross scaffolding (cross-tool env, stddef + C++ ABI flags, drv attrs)
  deploy-bundle.nix # relocatable bin/+lib/+terminfo/+CA tree (Term50 deploy output)
  files/           # syslog.h / langinfo.h shims, wcwidth_compat.h, qnx-compat.c
checks/            # validate.sh (toolchain), validate-elf.sh (built libs/binaries),
                   #   validate-bundle.sh (staged deploy bundle)
```

## Sysroot wiring

- **Model A — impure path (default).** Reference the gitignored `sdk/bbndk-linux`
  tree in place. Zero proprietary bytes in store or git; not a pure build.
  The path comes from `BBNIX_SYSROOT` (read at eval via `builtins.getEnv`) with
  **no default** — unset throws, so builds run `--impure`
  (`BBNIX_SYSROOT=/path nix build --impure .#gcc`).
- **Model B — `requireFile` store input.** Bring the sysroot into the store once,
  content-addressed; pure and cacheable. Marked `meta.license = unfree`.

The `qcc` spec-file driver (see README) already switches between the SDK's GCC
4.6.3 / 4.8.3 purely via `etc/qcc/gcc/<ver>/*.conf` — which is the seam bbnix's
own modern GCC slots into.

### Why not nixpkgs cross / BerryCore

- nixpkgs has **no QNX target** (`pkgsCross.qnx` does not exist), so each recipe is
  a bespoke derivation against bbnix's own toolchain — Nix is the reproducible
  *build harness*, not the package ecosystem.
- BerryCore ships working binaries but as a kitchen-sink distro. bbnix reuses its
  QNX porting *patches* (via `fetchpatch`) and treats its artifacts as a validation
  oracle, but builds everything from source itself.

## Per-package build notes

- **busybox** *(1.36.1 subset)* — fills gaps in the minimal QNX userland with a
  conservative applet set: basic coreutils, grep/sed/find/xargs, tar/gzip/bzip2/
  xz, clear/reset/resize. BusyBox is Linux-first, so applets needing `/proc`,
  Linux mount/process APIs, `utimensat`, or richer termios stay disabled until
  individually ported. The QNX port patches endian/byteswap detection, libc
  feature assumptions, `itoa`/`utoa` symbol collisions, two-arg `makedev`,
  `strndup`, and BSD-style `getopt` reset (`optind=1`). Symlink applets and
  `busybox APPLET ...` are smoke-tested on a Q10 over dev-mode SSH.
- **openssh** — client **and** sshd (OpenSSH 10.0p2), on from-source **OpenSSL
  3.x** + **zlib 1.3.x** (`.so.3`/`.so.1`, not the sysroot's EOL `.so.2`). Cross
  needs pre-seeded `ac_cv_*` cache vars, a `<syslog.h>` shim (QNX ships slog2), and
  a handful of QNX knobs — see `pkgs/openssh.nix` / `pkgs/openssl.nix`.
- **mosh** — **mosh-client** (1.4.0), the Blink model: device dials out to a Linux
  box running mosh-server. Rides our from-source OpenSSL 3.x (mosh 1.4 needs a
  crypto lib's AES) and embeds a static **protobuf 3.6.1** (host `protoc` + cross
  lib, see `pkgs/protobuf*.nix`). mosh-server on QNX is left as a separate
  experiment (forkpty / utmp).
- **tmux** — session persistence + multiplexing (3.5a). Embeds a static **libevent
  2.1.12** and links our `libncursesw`. QNX ships `forkpty(3)` only in the *static*
  libc (`libcS.a`), so we extract its `pty.o`/`posix_pty.o` PIC objects and link
  them straight in. tmux mandates a UTF-8 `LC_CTYPE`, but QNX's `setlocale` accepts
  only `C`/`POSIX`, so launch with `LC_ALL=C BBNIX_CODESET=UTF-8` (the latter makes
  `nl_langinfo` report UTF-8). See `pkgs/tmux.nix` / `pkgs/libevent.nix`.
- **zsh** — a richer interactive shell (5.9) than the device's minimal ksh /
  Term49's bundled mksh: completion, history, zle. Built as **one static binary**
  (`--disable-dynamic` links all modules in — no loadable `.so` tree, no `dlopen`
  Linux-isms). Links our `libncursesw` and rides QNX's own GNU **libiconv**
  (`libiconv.so.1`, already on-device) for UTF-8, so multibyte needs no extra
  deploy dep — and, unlike tmux, no `BBNIX_CODESET` trick (zsh's
  `--enable-multibyte` is compile-time, not locale-gated). See `pkgs/zsh.nix`.
- **ncurses** — widec (`libncursesw`), hard dependency for mosh / tmux / TUIs.
  The terminfo DB ships in the deploy bundle; on-device `TERM=xterm-256color`
  resolves to 256 colors.
- **libbbnixcompat** — a small shim lib filling QNX libc gaps the above hit: the
  `tsearch(3)` family, `wcwidth`, `nl_langinfo(CODESET)`, and the GCC-4.9-era C++
  ABI symbol `__cxa_throw_bad_array_new_length`. See `pkgs/qnx-compat.nix`.

## Build sequence

1. **Toolchain PoC** — binutils + GCC 9 against the sysroot; run the static
   `readelf` assertions on `hello.c` / `hello.cpp`. Validates the biggest unknown:
   *does from-source GCC 9 link the 2014 sysroot?*
2. `zlib` -> `openssl` -> `openssh` (OpenSSH needs zlib + libcrypto, **not**
   ncurses — that's for tmux/mosh in step 3).
3. `ncurses` + `mosh-client` + `tmux` (chains: `qnx-compat` -> `ncurses`;
   `protobuf-host`/`protobuf` + `openssl` -> `mosh`; `libevent` + `ncurses` ->
   `tmux`). zsh also lands here (`ncurses` -> `zsh`).
4. `busybox` subset, then mosh-server / Term49 packaging (the surprises live here).

## Validation tiers

1. **Toolchain sanity:** `-dumpmachine`, `__QNXNTO__`, `-print-sysroot`.
2. **Static:** `checks/validate.sh` for the toolchain (`hello.c`/`hello.cpp`),
   `checks/validate-elf.sh <binutils> <elf> [lib|exe]` for built libs/binaries.
   Asserts ARM EABI5, interp `/usr/lib/ldqnx.so.2`, `NEEDED libc.so.3`, the
   from-source crypto (`NEEDED .so.3`/`.so.1`, **never** the sysroot's `.so.2`),
   **no glibc / no `/nix/store` RUNPATH leak**. `checks/validate-bundle.sh
   <binutils> <bundle>` runs that per artifact across a staged deploy bundle and
   adds tree-wide asserts (no `/nix/store` text/symlink leak, `terminfo/` +
   `xterm-256color`, CA bundle present); wired as `checks.deploy-bundle` for
   `nix flake check --impure`.
3. **Runtime on device:** `bb-scp` the deploy bundle, `bb-ssh` smoke run, all
   verified on a Q10 (QNX 8.0.0 armle):
   - openssh: `ssh -V`, `ssh -Q cipher`, `ssh-keygen -t ed25519`.
   - mosh-client: version banner (all 9 NEEDED libs resolve), `mosh-client -c` ->
     `256` with `TERM=xterm-256color` (ncursesw + shipped terminfo).
   - tmux: `tmux -V`, then a detached session forks a real pty and round-trips
     `echo` through an in-pty `ksh` (`send-keys` + `capture-pane`), proving the
     static-libc forkpty objects work.
   - zsh: `zsh --version` -> 5.9, scripting/builtins, and UTF-8 string ops
     (`${#"héllo"}` -> 5, case-mapping preserves `é`) — multibyte works with no
     `BBNIX_CODESET` override.
   - busybox: `busybox --list`, direct `busybox echo`, and applet-symlink smoke
     tests for `uname`, `cat`, `grep`, `sed`, and `find` in
     `/accounts/1000/shared/documents`.

## Deploy

The userland deploys as a relocatable bundle: a `bin/` directory of binaries
beside a `lib/` of the from-source shared libs (plus `terminfo/` and a CA store).

### `nix build .#deploy-bundle` (Term50)

`pkgs/deploy-bundle.nix` stages that tree as a first-class output so Term50 can
pin bbnix as a flake input and drop the result under `app/native/bbnix` (Term50
resolves `$BBNIX_ROOT`, else `$SANDBOX/app/native/bbnix`, prepends `bin/`+`lib/`,
sets `TERMINFO`, and prefers `bin/zsh`). Three nested variants:

| attr | adds | for |
| --- | --- | --- |
| `.#deploy-bundle-minimal` | `zsh` `tmux` `busybox` + `libncursesw`/`libbbnixcompat` + `terminfo/` | interactive shell + POSIX utility subset |
| `.#deploy-bundle-ssh` | + `ssh scp sftp ssh-keygen` + `libssl`/`libcrypto`/`libz` + CA bundle | + OpenSSH client / HTTPS |
| `.#deploy-bundle-full` (= `.#deploy-bundle`) | + `mosh-client` + the `mosh` launcher + `curl` + `libbtcrash.so` | everything interactive |

```sh
nix build --impure --option sandbox relaxed .#deploy-bundle   # -> ./result
```

Layout (note `terminfo/` at the bundle root — what the launcher's `TERMINFO`
expects — not `share/terminfo`):

```text
result/bin/   zsh tmux busybox {cat,grep,sed,find,...} [ssh scp sftp ssh-keygen] [mosh-client mosh curl]
result/lib/   libncursesw.so.6 libbbnixcompat.so.1
                [libssl.so.3 libcrypto.so.3 libz.so.1] [libbtcrash.so]
result/terminfo/                         # ncurses DB (xterm-256color, …)
result/ssl/cacert.pem                    # ssh/full: WebPKI CA, from nixpkgs.cacert
result/etc/ssl/certs/ca-certificates.crt #          (Debian-style path too)
```

The bundle is relocatable — no `/nix/store` runtime assumptions. It also ships
its own activation manifest (`etc/bbnix-env`) and a sourceable POSIX-sh shim
(`etc/bbnix-activate`) that establishes the launch env every bundled binary
needs — see **Activation** below. The bundled `mosh` launcher already sources
it; external consumers (Term50) should apply the same manifest rather than
re-deriving bbnix's own invariants.

The canonical install root is **`/accounts/1000/shared/misc/bbnix`** (flake.nix's
`installRoot`). curl's compile-time CA default and openssl's `--openssldir` are
baked under it (`<root>/ssl/cacert.pem`), which is exactly where the bundle stages
`cacert.pem` — so **bare curl verifies HTTPS with no env wrapper** once the tree
is unpacked there. Unpacked anywhere else, point curl at the bundled cert with
`SSL_CERT_FILE=<root>/ssl/cacert.pem CURL_CA_BUNDLE=<root>/ssl/cacert.pem` (the
launcher does this); the rest of the tree stays relocatable regardless.

Validate the staged tree with `checks/validate-bundle.sh <binutils> <bundle>` (or
`nix flake check --impure`, which builds and checks `.#deploy-bundle-full`).

### Activation (`etc/bbnix-env` + `etc/bbnix-activate`)

The bundle is self-activating: a declarative manifest carries every env var
the bundled binaries need (the device loader has no `$ORIGIN`, tmux gates on
a UTF-8 locale QNX can't satisfy natively, and `/tmp → /dev/shmem` can't host
tmux's socket dir — all bbnix-specific knowledge, none of it derivable by the
consumer).

```
# etc/bbnix-env -- $ROOT expands to the bundle root, $HOME to the caller's.
set         BBNIX_CODESET=UTF-8     # forced -- tmux's nl_langinfo gate
set         LC_ALL=C                # forced -- QNX setlocale takes only C/POSIX
set         TERMINFO=$ROOT/terminfo
prepend     PATH=$ROOT/bin
prepend     LD_LIBRARY_PATH=$ROOT/lib
default     TMUX_TMPDIR=$HOME       # soft -- dodge /dev/shmem default
default     TERM=xterm-256color
set-if-file SSL_CERT_FILE=$ROOT/ssl/cacert.pem      # ssh/full only;
set-if-file CURL_CA_BUNDLE=$ROOT/ssl/cacert.pem     # the manifest itself
set-if-file GIT_SSL_CAINFO=$ROOT/ssl/cacert.pem     # encodes the variant
set-if-dir  SSL_CERT_DIR=$ROOT/etc/ssl/certs        # guard, not consumers.
```

Modes: `set` overwrites, `default` only if unset/empty, `prepend` composes as
`<new>[:<existing>]`, and `set-if-file`/`set-if-dir` apply `set` only when
the (expanded) value names an existing file/directory — so the same manifest
ships in every variant and self-skips on minimal. `BBNIX_CODESET=UTF-8` and
`LC_ALL=C` are both `set` (not `default`): QNX's `setlocale` rejects every
locale name except `C`/`POSIX` (see `pkgs/files/qnx-compat.c`), so a common
inherited `LC_ALL=en_US.UTF-8` (any modern ssh client exports it) would
crash the bundled tmux's `setlocale("")` gate. Forcing `LC_ALL=C` is the
only POSIX-locale value tmux accepts, and `BBNIX_CODESET` independently
satisfies the `nl_langinfo(CODESET)` gate.

Two ways to apply:

- **Shell** (interactive ssh, scripts, the bundled `mosh` launcher):

  ```sh
  BBNIX_ROOT=/accounts/1000/shared/misc/bbnix \
    . /accounts/1000/shared/misc/bbnix/etc/bbnix-activate
  ```

  POSIX-sh, sourceable under `/bin/sh` / busybox-sh / bash / zsh-as-sh. Pure
  shell builtins — no `sed`/`awk`/`grep` — so it's safe to source before
  `PATH` has been composed. `BBNIX_ROOT` is required from the caller —
  resolving a sourced script's own path is non-portable in POSIX sh.

- **Programmatic** (Term50): parse `etc/bbnix-env` in C and apply each line
  before `fork`/`exec`, so the env reaches `zsh`, `sh -c`, and tmux alike.
  Each mode maps to a straightforward C step:
  - `set`     → `setenv(k, v, 1)`
  - `default` → `if (!getenv(k) || !*getenv(k)) setenv(k, v, 1);` (the shim
    treats an exported-but-empty value as unset, matching `${VAR:=...}`;
    plain `setenv(k, v, 0)` would leave an empty inherited value in place)
  - `prepend` → compose `v[:existing]` and `setenv(k, …, 1)`
  - `set-if-file`/`set-if-dir` → `stat()` the expanded value; `setenv(k, v, 1)`
    only on success

  Term50's `setup_bbnix_env` (`src/main.c`) is the existing consumer;
  converting it to read this manifest replaces the hardcoded list — and,
  importantly, the SSL/variant skip policy stays in bbnix where it can
  evolve without a Term50 change.

### By hand

To cherry-pick from the store outputs directly instead:

```sh
# assemble bin/ + lib/ from the store outputs
mkdir -p bundle/bin bundle/lib
cp $(nix path-info .#openssh)/bin/{ssh,scp,sftp,ssh-keygen} bundle/bin/
cp $(nix path-info .#openssh)/bin/sshd                       bundle/bin/   # + libexec/sshd-* for the server
cp $(nix path-info .#openssl)/lib/lib{crypto,ssl}.so.3       bundle/lib/
cp $(nix path-info .#zlib)/lib/libz.so.1.3.1                 bundle/lib/libz.so.1
# push to the device (see the bb-device-ssh runbook), then run with:
LD_LIBRARY_PATH=<dir>/lib  <dir>/bin/ssh ...
```

**Why `LD_LIBRARY_PATH`, not RUNPATH:** the binaries link the from-source
`libcrypto.so.3` / `libssl.so.3` / `libz.so.1`, which are **not** on the device
(only the EOL `.so.2` is). They must ship in the bundle. The device's 2018
`ldqnx.so.2` does **not expand `$ORIGIN`** (in either `DT_RPATH` or `DT_RUNPATH`),
so a relocatable `$ORIGIN/../lib` RUNPATH is useless — the recipes ship **no
RPATH** and the launcher sets `LD_LIBRARY_PATH=<dir>/lib` instead (which also lets
`libssl` find `libcrypto`). An absolute RPATH baked to a fixed device path also
works if a self-contained binary is ever needed.

**mosh-client** deploys the same way: `mosh-client` beside a `lib/` of
`libncursesw.so.6` + `libssl.so.3` + `libcrypto.so.3` + `libz.so.1` +
`libbbnixcompat.so.1` (the rest — `libstdc++.so.6`, `libsocket`, `libm`, `libc` —
are on the device; protobuf is statically embedded). Ship `share/terminfo` too and
launch with `LD_LIBRARY_PATH=<dir>/lib TERMINFO=<dir>/terminfo
TERM=xterm-256color`. The `mosh` perl wrapper isn't used on-device (no perl);
Term49 invokes `mosh-client` directly.

**tmux** deploys with only `libncursesw.so.6` + `libbbnixcompat.so.1` in `lib/`
(libevent and the pty objects are statically embedded; `libsocket`/`libm`/`libc`
are on the device). Launch via the bundle's activation shim — `BBNIX_ROOT=<dir>
. <dir>/etc/bbnix-activate; tmux new` — which sets the `LC_ALL=C
BBNIX_CODESET=UTF-8` pair tmux's UTF-8 `LC_CTYPE` gate requires (QNX's
`setlocale` rejects every `.UTF-8` locale name, so `LC_ALL=C` keeps `setlocale`
happy while `BBNIX_CODESET` makes `libbbnixcompat`'s `nl_langinfo(CODESET)`
report UTF-8) plus the writable `TMUX_TMPDIR=$HOME` that dodges the
`/dev/shmem` socket-dir failure.

**zsh** deploys into the *same* bundle as tmux — it reuses `libncursesw.so.6` +
`libbbnixcompat.so.1` in `lib/` and the terminfo DB (`libiconv.so.1`/`libsocket`/
`libm`/`libc` are on-device; all modules are statically linked in). Launch with
`LD_LIBRARY_PATH=<dir>/lib TERMINFO=<dir>/terminfo TERM=xterm-256color`, then
`zsh`. No `LC_ALL`/`BBNIX_CODESET` is required. Switching Term49's default shell
from mksh to zsh is a separate, optional follow-up.

**busybox** deploys in `bin/` as `busybox` plus relative applet symlinks. It only
needs on-device `libsocket.so.3` + `libc.so.3`, so no extra bundle libraries are
required. Device-smoke examples: `busybox echo`, `uname`, `cat`, `grep`, `sed`,
and `find` over `/accounts/1000/shared/documents`.

**sshd** additionally needs, at deploy time: host keys (`ssh-keygen -A`), an `sshd`
privsep user, and `/var/empty` (mode 700, root-owned) — none are build-time
concerns. The binaries embed `--sysconfdir=/accounts/1000/shared/misc/etc/ssh`;
sample `sshd_config`/`ssh_config` ship under the openssh output's `etc/ssh/`.
