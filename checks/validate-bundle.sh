#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# bbnix deploy-bundle validation (pkgs/deploy-bundle.nix).
#
# Usage: validate-bundle.sh <binutils-prefix> <bundle-dir>
#   binutils-prefix  result of .#binutils (provides target readelf)
#   bundle-dir       a built .#deploy-bundle{,-minimal,-ssh,-full} tree
#
# Asserts the staged tree is what Term50 can drop into app/native/bbnix:
#   - every bin/ ELF is a BB10/QNX armle-v7 executable, every lib/ .so a library
#     (delegated to the sibling validate-elf.sh: interp, NEEDED, no .so.2/glibc,
#     no /nix/store RUNPATH);
#   - no /nix/store leak in any text artifact (scripts/configs) and no symlink
#     pointing into the store (the recipe derefs sonames with cp -L);
#   - terminfo/ is populated with an xterm-256color entry;
#   - when the OpenSSH client is present (ssh/full), the relocatable CA bundle
#     ships at ssl/cacert.pem and etc/ssl/certs/ca-certificates.crt.
set -euo pipefail

BU_PREFIX="${1:?binutils prefix}"
# Resolve to the physical path so a `nix build -o result` gc-root symlink isn't
# itself flagged by the in-tree symlink scan below.
BUNDLE="$(cd "${2:?bundle dir}" && pwd -P)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_ELF="$HERE/validate-elf.sh"

[ -x "$VALIDATE_ELF" ] || { echo "FAIL: missing sibling validate-elf.sh"; exit 1; }

# ELF magic (\x7fELF) without depending on file(1), which isn't on the check
# sandbox PATH. od is coreutils.
is_elf() { [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' ')" = "7f454c46" ]; }

echo "== deploy-bundle: $BUNDLE =="

# 1. Per-artifact ELF checks. bin/ holds executables (including the sh-launcher
#    ELF shipped as bin/mosh - issue #6); lib/ holds shared objects.
#    validate-elf.sh exits non-zero on any failure, which aborts us under set -e.
shopt -s nullglob
for f in "$BUNDLE"/bin/*; do
  if is_elf "$f"; then
    bash "$VALIDATE_ELF" "$BU_PREFIX" "$f" exe
  else
    echo "-- skip non-ELF $f (launcher script)"
  fi
done

# Whenever the bundle ships mosh, bin/mosh must be the sh-launcher ELF (a bare
# shell script there lands non-executable after BB10 install) AND the real
# launcher must travel as a non-empty libexec/ sidecar. Key off mosh-client,
# which is always present with the launcher, so dropping *both* mosh files can't
# silently skip this (issue #6).
if [ -e "$BUNDLE/bin/mosh-client" ]; then
  is_elf "$BUNDLE/bin/mosh" || { echo "FAIL: bin/mosh is not an ELF (issue #6)"; exit 1; }
  [ -s "$BUNDLE/libexec/mosh" ] || { echo "FAIL: missing/empty libexec/mosh sidecar (issue #6)"; exit 1; }
  echo "  mosh launcher (ELF + libexec sidecar) OK"
fi
for f in "$BUNDLE"/lib/*.so*; do
  bash "$VALIDATE_ELF" "$BU_PREFIX" "$f" lib
done

# 2. No /nix/store leak. -I limits the scan to text artifacts (scripts/configs):
#    unstripped ARM ELFs carry DWARF build paths that are not runtime
#    assumptions, and validate-elf.sh already proved their RUNPATH is clean.
if grep -rlI /nix/store "$BUNDLE"; then
  echo "FAIL: /nix/store path in a text artifact above"; exit 1
fi
# The recipe derefs sonames with cp -L, so the tree should hold no symlinks at
# all — certainly none into the store.
while IFS= read -r link; do
  tgt="$(readlink "$link")"
  case "$tgt" in
    /nix/store/*) echo "FAIL: symlink into store: $link -> $tgt"; exit 1 ;;
  esac
done < <(find "$BUNDLE" -type l)

# 3. terminfo DB present with the default 256-color entry.
[ -d "$BUNDLE/terminfo" ] || { echo "FAIL: no terminfo/"; exit 1; }
find "$BUNDLE/terminfo" -name 'xterm-256color' -print -quit | grep -q . \
  || { echo "FAIL: terminfo/ has no xterm-256color entry"; exit 1; }
echo "  terminfo OK"

# 4. A bundle that ships the from-source TLS stack (libssl) must also carry the
#    relocatable trust store its HTTPS tools verify against — they travel
#    together in the ssh/full variants. Key off the lib, not an arbitrary tool.
if [ -e "$BUNDLE/lib/libssl.so.3" ]; then
  [ -s "$BUNDLE/ssl/cacert.pem" ] \
    || { echo "FAIL: missing/empty ssl/cacert.pem"; exit 1; }
  [ -s "$BUNDLE/etc/ssl/certs/ca-certificates.crt" ] \
    || { echo "FAIL: missing/empty etc/ssl/certs/ca-certificates.crt"; exit 1; }
  echo "  CA bundle OK"
fi

echo "== PASS ($BUNDLE) =="
