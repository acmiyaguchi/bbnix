# bbnix

A minimal, from-source cross-build userland for **BlackBerry 10 / QNX 8**
(`armle-v7`), expressed as Nix derivations. The goal is a small remote-dev
toolkit in the spirit of [Blink](https://blink.sh) — not a sprawling package
distribution.

This is the **implementation** repo. Planning and design discussion live in
`blackberry-meta` (see issue #4, the modern GCC cross-toolchain). The terminal
*app* that runs these binaries on-device is a separate checkout (`Term49`);
bbnix only builds the userland it executes.

## Scope

| | |
|---|---|
| **In** | The cross-toolchain + recipes for ncurses, OpenSSH, mosh, tmux, and a busybox subset. All open source (GPL/BSD/Apache), public source + hashes. |
| **Out** | The QNX 8 / BB10 sysroot (`target_10_3_1_995`) — proprietary, **never committed**, supplied at build time. The terminal app (Term49). |

## The open / proprietary split

The SDK's `qcc` is a spec-file driver, not a compiler; it already selects
between GCC 4.6.3 / 4.8.3 purely via `etc/qcc/gcc/<ver>/*.conf`. bbnix builds a
**modern GCC** cross-compiler from source and links it against the user's
sysroot, so we can build current C++ (mosh) and harden the network daemons
without being pinned to the 2014 GCC.

Sysroot wiring (see `blackberry-meta#4` for detail):

- **Model A — impure path (default here).** Reference the gitignored
  `sdk/bbndk-linux` tree in place. Zero proprietary bytes in store or git; not a
  pure build. `BBNIX_SYSROOT` overrides the path.
- **Model B — `requireFile` store input.** Bring the sysroot into the store once,
  content-addressed; pure and cacheable. Marked `meta.license = unfree`.

## Why not nixpkgs cross / BerryCore

- nixpkgs has **no QNX target** (`pkgsCross.qnx` does not exist), so each recipe
  is a bespoke derivation against bbnix's own toolchain — Nix is the reproducible
  *build harness*, not the package ecosystem.
- BerryCore ships working binaries but as a kitchen-sink distro. bbnix reuses its
  QNX porting *patches* (via `fetchpatch`) and treats its artifacts as a
  validation oracle, but builds everything from source itself.

## Target set

- `busybox` *(subset)* — fills gaps in the minimal QNX userland. The soft spot:
  busybox is written against Linux (`/proc`, Linux syscalls), so expect a patched
  subset, not a clean full build. Open question: a small portable coreutils set
  may beat dragging in busybox's Linux assumptions.
- `openssh` ✅ *built + device-tested* — client **and** sshd (OpenSSH 10.0p2),
  on from-source **OpenSSL 3.x** + **zlib 1.3.x** (`.so.3`/`.so.1`, not the
  sysroot's EOL `.so.2`). Cross needs pre-seeded `ac_cv_*` cache vars, a
  `<syslog.h>` shim (QNX ships slog2), and a handful of QNX knobs — see
  `pkgs/openssh.nix` / `pkgs/openssl.nix` and the **Deploy** section below.
- `mosh` ✅ *built + device-tested* — **mosh-client** (1.4.0), the Blink model:
  device dials out to a real Linux box running mosh-server. Rides our
  from-source OpenSSL 3.x (mosh 1.4 needs a crypto lib's AES) and embeds a
  static **protobuf 3.6.1** (host `protoc` + cross lib, see `pkgs/protobuf*.nix`).
  mosh-server on QNX is left as a separate experiment (forkpty / utmp).
- `tmux` ✅ *built + device-tested* — session persistence + multiplexing (3.5a).
  Embeds a static **libevent 2.1.12** and links our `libncursesw`. QNX ships
  `forkpty(3)` only in the *static* libc (`libcS.a`), so we extract its
  `pty.o`/`posix_pty.o` PIC objects and link them straight in — verified on the
  Q10: a detached session forks a real pty and round-trips shell I/O. tmux
  mandates a UTF-8 `LC_CTYPE`, but QNX's `setlocale` accepts only `C`/`POSIX`, so
  launch with `LC_ALL=C BBNIX_CODESET=UTF-8` (the latter makes our
  `nl_langinfo` report UTF-8). See `pkgs/tmux.nix` / `pkgs/libevent.nix`.
- `ncurses` ✅ *built* + **terminfo** — widec (`libncursesw`), hard dependency
  for mosh / tmux / TUIs. The terminfo DB ships in the deploy bundle; on-device
  `TERM=xterm-256color` resolves to 256 colors (verified via `mosh-client -c`).
- `libbbnixcompat` — a small shim lib filling QNX libc gaps that the above hit:
  the `tsearch(3)` family, `wcwidth`, `nl_langinfo(CODESET)`, and the GCC-4.9-era
  C++ ABI symbol `__cxa_throw_bad_array_new_length`. See `pkgs/qnx-compat.nix`.

## Build sequence

1. ✅ **Toolchain PoC** — binutils + GCC 9 against the sysroot; run the static
   `readelf` assertions on `hello.c` / `hello.cpp`. Validates the single biggest
   unknown: *does from-source GCC 9 link the 2014 sysroot?*
2. ✅ `zlib` → `openssl` → `openssh` (OpenSSH needs zlib + libcrypto, **not**
   ncurses — that was a planning error; ncurses is for tmux/mosh in step 3).
3. ✅ `ncurses` + `mosh-client` + `tmux` (chains: `qnx-compat` → `ncurses`;
   `protobuf-host`/`protobuf` + `openssl` → `mosh`; `libevent` + `ncurses` →
   `tmux`).
4. `busybox` subset, then mosh-server / Term49 packaging (the surprises live here).

## Validation tiers

1. **Toolchain sanity:** `-dumpmachine`, `__QNXNTO__`, `-print-sysroot`.
2. **Static:** `checks/validate.sh` for the toolchain (`hello.c`/`hello.cpp`),
   `checks/validate-elf.sh <binutils> <elf> [lib|exe]` for built libs/binaries.
   Asserts ARM EABI5, interp `/usr/lib/ldqnx.so.2`, `NEEDED libc.so.3`, the
   from-source crypto (`NEEDED .so.3`/`.so.1`, **never** the sysroot's `.so.2`),
   **no glibc / no `/nix/store` RUNPATH leak**.
3. ✅ **Runtime on device:** `bb-scp` the deploy bundle, `bb-ssh` smoke run.
   OpenSSH verified on a Q10 (QNX 8.0.0 armle): `ssh -V`, `ssh -Q cipher`,
   `ssh-keygen -t ed25519`. mosh-client verified on the same Q10: version
   banner (all 9 NEEDED libs resolve), and `mosh-client -c` →
   `256` with `TERM=xterm-256color` (ncursesw + shipped terminfo). tmux verified
   on the same Q10: `tmux -V`, then a detached session forks a real pty and
   round-trips `echo` through an in-pty `ksh` (`send-keys` + `capture-pane`),
   proving the static-libc forkpty objects work. See **Deploy**.

## Layout

```
flake.nix          # devShell + package wiring (Model A sysroot by default)
toolchain/         # binutils, gcc recipes (+ files/, patches/)
pkgs/              # userland recipes: zlib, openssl, openssh, ncurses, mosh,
                   #   protobuf (+ protobuf-host), libevent, tmux, qnx-compat
                   #   (then busybox)
  qnx-common.nix   # shared cross scaffolding (cross-tool env, stddef + C++ ABI flags, drv attrs)
  files/           # syslog.h / langinfo.h shims, wcwidth_compat.h, qnx-compat.c
checks/            # validate.sh (toolchain), validate-elf.sh (built libs/binaries)
```

## Usage

```sh
nix develop                          # enters the bbnix shell; reports target + sysroot
BBNIX_SYSROOT=/path nix develop      # override the BYO sysroot location

# Model A reads the sysroot in place, so package builds need the relaxed sandbox:
nix build --option sandbox relaxed .#zlib .#openssl .#openssh
```

## Deploy

The userland deploys as a relocatable bundle: a `bin/` directory of binaries
beside a `lib/` of the from-source shared libs.

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
`ldqnx.so.2` does **not expand `$ORIGIN`** (in either `DT_RPATH` or
`DT_RUNPATH`), so a relocatable `$ORIGIN/../lib` RUNPATH is useless — the
recipes ship **no RPATH** and the launcher sets `LD_LIBRARY_PATH=<dir>/lib`
instead (which also lets `libssl` find `libcrypto`). An absolute RPATH baked to
a fixed device path also works if a self-contained binary is ever needed.

**mosh-client** deploys the same way: `mosh-client` beside a `lib/` of
`libncursesw.so.6` + `libssl.so.3` + `libcrypto.so.3` + `libz.so.1` +
`libbbnixcompat.so.1` (the rest — `libstdc++.so.6`, `libsocket`, `libm`, `libc`
— are on the device; protobuf is statically embedded). Ship `share/terminfo`
too and launch with `LD_LIBRARY_PATH=<dir>/lib TERMINFO=<dir>/terminfo
TERM=xterm-256color`. The `mosh` perl wrapper isn't used on-device (no perl);
Term49 invokes `mosh-client` directly.

**tmux** deploys with only `libncursesw.so.6` + `libbbnixcompat.so.1` in `lib/`
(libevent and the pty objects are statically embedded; `libsocket`/`libm`/`libc`
are on the device). Launch with `LD_LIBRARY_PATH=<dir>/lib
TERMINFO=<dir>/terminfo TERM=xterm-256color LC_ALL=C BBNIX_CODESET=UTF-8`, then
`tmux new`. The `LC_ALL=C BBNIX_CODESET=UTF-8` pair is required: tmux gates on a
UTF-8 `LC_CTYPE`, but QNX's `setlocale` rejects every `.UTF-8` locale name, so
`LC_ALL=C` keeps `setlocale` happy while `BBNIX_CODESET` makes `libbbnixcompat`'s
`nl_langinfo(CODESET)` report UTF-8. Verified on the Q10 (forkpty round-trips a
real `ksh` pty).

`sshd` additionally needs, at deploy time: host keys (`ssh-keygen -A`), an `sshd`
privsep user, and `/var/empty` (mode 700, root-owned) — none are build-time
concerns. The binaries embed `--sysconfdir=/accounts/1000/shared/misc/etc/ssh`;
sample `sshd_config`/`ssh_config` ship under the openssh output's `etc/ssh/`.

## License

bbnix-original code (the Nix recipes, flake, and checks) is MIT (see `LICENSE`).
The GCC target-config files under `toolchain/files/gcc9/` and the patch under
`toolchain/patches/` are GPL-3.0-or-later GCC-derived source, forward-ported
from the BlackBerry/QNX GCC 4.9 fork (full texts in
`toolchain/files/gcc9/COPYING3` and `toolchain/files/gcc9/COPYING.RUNTIME`); see
`NOTICE` for the exact split. The proprietary QNX/BB10
sysroot is never distributed — bring your own.
