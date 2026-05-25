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
- `openssh` — client **and** sshd. Low risk; the device already runs a dev-mode
  sshd. Pre-seed configure cache vars for cross.
- `mosh` — **client is the priority** (Blink model: device dials out to a real
  Linux box running mosh-server). mosh-server on QNX is the genuine experiment
  (UDP bind / locale / socket options). Pulls in protobuf (needs a matching host
  `protoc`).
- `tmux` — session persistence + multiplexing. Needs libevent + ncurses.
- `ncurses` + **terminfo** — hard dependency for mosh / tmux / TUIs. A UTF-8
  locale and a `*-256color` terminfo entry are the usual "runs but renders
  garbage" trap.

## Build sequence

1. **Toolchain PoC** — binutils + GCC 9 against the sysroot; run the static
   `readelf` assertions on `hello.c` / `hello.cpp`. Validates the single biggest
   unknown: *does from-source GCC 9 link the 2014 sysroot?*
2. `ncurses` → `openssh`
3. `tmux` + `mosh-client`
4. `busybox` subset, then mosh-server / Term49 packaging (the surprises live here).

## Validation tiers

1. **Toolchain sanity:** `-dumpmachine`, `__QNXNTO__`, `-print-sysroot`.
2. **Static (`nix flake check`):** SDK `readelf` asserts ARM EABI5, interpreter
   `/usr/lib/ldqnx.so.2`, `NEEDED libc.so.3`, **no glibc / no `/nix/store`
   RUNPATH leak**, `.comment` shows GCC 9. Compare to a qcc-built reference.
3. **Runtime on device:** `bb-scp` + `bb-ssh` smoke run; exercise libstdc++ ABI
   for C++; `pidin` to confirm library load.

## Layout

```
flake.nix      # devShell + package wiring (Model A sysroot by default)
toolchain/     # qnx-binutils, qnx-gcc recipes
pkgs/          # ncurses, openssh, mosh, tmux, busybox recipes
```

## Usage

```sh
nix develop                 # enters the bbnix shell; reports target + sysroot
BBNIX_SYSROOT=/path nix develop   # override the BYO sysroot location
```

## License

bbnix-original code (the Nix recipes, flake, and checks) is MIT (see `LICENSE`).
The GCC target-config files under `toolchain/files/gcc9/` and the patch under
`toolchain/patches/` are GPL-3.0-or-later GCC-derived source, forward-ported
from the BlackBerry/QNX GCC 4.9 fork (full texts in
`toolchain/files/gcc9/COPYING3` and `toolchain/files/gcc9/COPYING.RUNTIME`); see
`NOTICE` for the exact split. The proprietary QNX/BB10
sysroot is never distributed — bring your own.
