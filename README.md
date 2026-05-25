# bbnix

A minimal, from-source cross-build userland for **BlackBerry 10 / QNX 8**
(`armle-v7`), expressed as Nix derivations — a small remote-dev toolkit in the
spirit of [Blink](https://blink.sh), not a package distribution.

This is the **implementation** repo. Design discussion lives in `blackberry-meta`
(issue #4, the modern GCC cross-toolchain); the on-device terminal app (`Term49`)
is a separate checkout. Engineering detail — per-package build notes, deploy
recipes, validation — lives in [`AGENTS.md`](AGENTS.md).

> This repo is developed and maintained largely by LLM agents (hence `AGENTS.md`),
> under human review. Expect commits and docs to reflect that.

## Scope

| | |
|---|---|
| **In** | The cross-toolchain + recipes for ncurses, OpenSSH, mosh, tmux, zsh, and a busybox subset. All open source, built from public source + hashes. |
| **Out** | The QNX 8 / BB10 sysroot (`target_10_3_1_995`) — proprietary, **never committed**, supplied at build time. The terminal app (Term49). |

## Open / proprietary split

The SDK's `qcc` is a spec-file driver, not a compiler. bbnix instead builds a
**modern GCC** from source and links it against the user's sysroot, so it can
build current C++ and harden the daemons without being pinned to the 2014 GCC.
The proprietary sysroot is never committed: by default it's referenced in place
(Model A, impure; `BBNIX_SYSROOT` overrides the path), or brought into the store
via `requireFile` for a pure build (Model B). See [`AGENTS.md`](AGENTS.md) and
`blackberry-meta#4` for the wiring.

## Targets

| Package | Version | Status | Note |
|---|---|---|---|
| `gcc` / `binutils` | 9 | built | modern cross-compiler against the BYO sysroot |
| `openssh` | 10.0p2 | device-tested | client + sshd, on from-source OpenSSL 3.x + zlib 1.3.x |
| `mosh` | 1.4.0 | device-tested | mosh-client (dial-out to a Linux mosh-server); static protobuf |
| `tmux` | 3.5a | device-tested | static libevent; forkpty via the static-libc pty objects |
| `zsh` | 5.9 | device-tested | one static binary; GNU libiconv multibyte (no locale gate) |
| `ncurses` | 6.4 | built | widec `libncursesw` + terminfo; hard dep for mosh / tmux / TUIs |
| `libbbnixcompat` | — | built | shim for QNX libc gaps (tsearch, wcwidth, nl_langinfo, C++ ABI) |
| `busybox` | subset | planned | fills minimal-userland gaps; Linux-isms make it the soft spot |

## Usage

```sh
nix develop                          # enters the bbnix shell; reports target + sysroot
BBNIX_SYSROOT=/path nix develop      # override the BYO sysroot location

# Model A reads the sysroot in place, so package builds need the relaxed sandbox:
nix build --option sandbox relaxed .#zlib .#openssl .#openssh
```

The userland deploys as a relocatable `bin/` + `lib/` bundle pushed to the device;
see [`AGENTS.md`](AGENTS.md) for per-package bundle contents and launch env.

## License

bbnix-original code (recipes, flake, checks) is MIT (see `LICENSE`). The GCC
target-config files under `toolchain/files/gcc9/` and the patch under
`toolchain/patches/` are GPL-3.0-or-later, forward-ported from the BlackBerry/QNX
GCC 4.9 fork — see `NOTICE` for the exact split. The proprietary QNX/BB10 sysroot
is never distributed; bring your own.
