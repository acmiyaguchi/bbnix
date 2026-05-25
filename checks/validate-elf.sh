#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# bbnix userland ELF validation (pkgs/: zlib, openssl, openssh).
#
# Usage: validate-elf.sh <binutils-prefix> <elf-file> [lib|exe]
#   binutils-prefix  result of .#binutils (provides target readelf)
#   elf-file         a built .so or executable to check
#   mode             lib (no interp; default if filename matches *.so*) or exe
#
# Generalizes checks/validate.sh's hello-world asserts to arbitrary built ELFs.
# Asserts the binary is a real BB10/QNX armle-v7 artifact AND links our
# from-source crypto (NEEDED .so.3/.so.1), never the sysroot's prebuilt .so.2.
set -euo pipefail

BU_PREFIX="${1:?binutils prefix}"
ELF="${2:?elf file}"
TARGET=arm-unknown-nto-qnx8.0.0eabi
READELF="$BU_PREFIX/bin/$TARGET-readelf"

# Default mode from the filename: anything with .so is a library (no interp).
case "${3:-}" in
  lib|exe) MODE="$3" ;;
  *) case "$ELF" in *.so|*.so.*) MODE=lib ;; *) MODE=exe ;; esac ;;
esac

echo "== $ELF ($MODE) =="

hdr="$("$READELF" -h "$ELF")"
echo "$hdr" | grep -q "Machine:.*ARM" || { echo "FAIL: not ARM"; exit 1; }
etype="$(echo "$hdr" | awk -F: '/Type:/{print $2}' | tr -d ' ')"
case "$MODE:$etype" in
  lib:DYN*) echo "  ELF type: DYN (shared object)" ;;
  exe:EXEC*) echo "  ELF type: EXEC (dynamically linked)" ;;
  exe:DYN*) echo "  ELF type: DYN (PIE)" ;;
  *) echo "FAIL: unexpected type $etype for mode $MODE"; exit 1 ;;
esac
echo "$hdr" | grep -Eq "Flags:.*0x5000202|Flags:.*Version5 EABI.*soft-float" \
  || echo "WARN: flags not the expected 0x5000202 (Version5 EABI soft-float)"

if [ "$MODE" = exe ]; then
  interp="$("$READELF" -l "$ELF" | grep -o '/usr/lib/ldqnx.so.2' | head -1 || true)"
  [ "$interp" = "/usr/lib/ldqnx.so.2" ] || { echo "FAIL: interp != /usr/lib/ldqnx.so.2"; exit 1; }
  echo "  interp: $interp"
fi

dyn="$("$READELF" -d "$ELF")"
echo "$dyn" | grep -q "NEEDED.*libc.so.3" || { echo "FAIL: missing NEEDED libc.so.3"; exit 1; }

# The project-specific assertion: we must link our from-source OpenSSL 3.x /
# zlib 1.3.x (.so.3 / .so.1), never the sysroot's EOL prebuilt .so.2.
if echo "$dyn" | grep -Eq "NEEDED.*(libcrypto\.so\.2|libssl\.so\.2|libz\.so\.2)"; then
  echo "FAIL: links the sysroot's prebuilt .so.2 (should be from-source .so.3/.so.1)"; exit 1
fi
# No glibc / no Linux loader leak.
echo "$dyn" | grep -Eq "NEEDED.*libc.so.6|NEEDED.*ld-linux" && { echo "FAIL: glibc leak"; exit 1; } || true

# RUNPATH must be the relocatable $ORIGIN form (or empty), never a store path.
rp="$(echo "$dyn" | grep -E "RPATH|RUNPATH" || true)"
if [ -n "$rp" ]; then
  echo "$rp" | grep -q "/nix/store" && { echo "FAIL: /nix/store RUNPATH leak"; exit 1; } || true
  echo "$rp" | grep -q '\$ORIGIN' || echo "WARN: RUNPATH set but not \$ORIGIN-relative"
fi
echo "  NEEDED OK ($(echo "$dyn" | grep -c NEEDED) libs); no .so.2 / glibc / store leak"

echo "== PASS ($ELF) =="
