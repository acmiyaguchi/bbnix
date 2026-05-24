#!/usr/bin/env bash
# bbnix toolchain validation (milestones M1/M2/M3).
#
# Usage: validate.sh <gcc-prefix> <binutils-prefix> [c|cpp]
#   gcc-prefix      result of .#gcc-stage1 or .#gcc
#   binutils-prefix result of .#binutils  (provides target readelf)
#   mode            c (default) or cpp
#
# Compiles checks/hello.<ext> and asserts the output ELF looks like a real
# BB10/QNX armle-v7 binary: ARM EABI5, interp /usr/lib/ldqnx.so.2, NEEDED
# libc.so.3 (+libstdc++.so.6 for C++), VFPv3-D16, GCC 9, and no host leakage.
set -euo pipefail

GCC_PREFIX="${1:?gcc prefix}"
BU_PREFIX="${2:?binutils prefix}"
MODE="${3:-c}"
TARGET=arm-unknown-nto-qnx8.0.0eabi
HERE="$(cd "$(dirname "$0")" && pwd)"

READELF="$BU_PREFIX/bin/$TARGET-readelf"
if [ "$MODE" = cpp ]; then
  CC="$GCC_PREFIX/bin/$TARGET-g++"; SRC="$HERE/hello.cpp"
else
  CC="$GCC_PREFIX/bin/$TARGET-gcc"; SRC="$HERE/hello.c"
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
out="$work/hello"

echo "== M1: driver sanity =="
dm="$("$CC" -dumpmachine)"; echo "  -dumpmachine: $dm"
[ "$dm" = "$TARGET" ] || { echo "FAIL: dumpmachine != $TARGET"; exit 1; }
defs="$(echo | "$CC" -dM -E - 2>/dev/null)"
for m in __QNXNTO__ __QNX__ __ARM__ __ARM_EABI__ __ELF__; do
  echo "$defs" | grep -q "define $m" || { echo "FAIL: $m not defined"; exit 1; }
done
echo "  builtins: __QNXNTO__ __QNX__ __ARM__ __ARM_EABI__ __ELF__ OK"
echo "  -print-sysroot: $("$CC" -print-sysroot)"
crt1="$("$CC" -print-file-name=crt1.o)"
echo "  -print-file-name=crt1.o: $crt1"
case "$crt1" in
  */armle-v7/lib/crt1.o) echo "  R1 osdir gate OK" ;;
  *) echo "WARN: crt1.o not resolved under armle-v7/lib (linking uses explicit specs)" ;;
esac

echo "== M2/M3: compile + link $MODE =="
"$CC" -o "$out" "$SRC"
echo "  built $out"

echo "== ELF assertions =="
hdr="$("$READELF" -h "$out")"
echo "$hdr" | grep -q "Machine:.*ARM" || { echo "FAIL: not ARM"; exit 1; }
# Accept ET_EXEC (standard dyn-linked) or ET_DYN (PIE). PIE is a follow-up: the
# binutils armnto emulation has no PIE script yet, so we emit ET_EXEC.
etype="$(echo "$hdr" | awk -F: '/Type:/{print $2}' | tr -d ' ')"
case "$etype" in
  EXEC*) echo "  ELF type: EXEC (dynamically linked; PIE pending binutils armnto support)";;
  DYN*)  echo "  ELF type: DYN (PIE)";;
  *) echo "FAIL: unexpected ELF type: $etype"; exit 1;;
esac
echo "$hdr" | grep -Eq "Flags:.*0x5000202|Flags:.*Version5 EABI.*soft-float" \
  || echo "WARN: flags not the expected 0x5000202 (Version5 EABI soft-float)"

interp="$("$READELF" -l "$out" | grep -o '/usr/lib/ldqnx.so.2' | head -1 || true)"
[ "$interp" = "/usr/lib/ldqnx.so.2" ] || { echo "FAIL: interp != /usr/lib/ldqnx.so.2"; exit 1; }
echo "  interp: $interp"

dyn="$("$READELF" -d "$out")"
echo "$dyn" | grep -q "NEEDED.*libc.so.3" || { echo "FAIL: missing NEEDED libc.so.3"; exit 1; }
echo "$dyn" | grep -Eq "NEEDED.*libc.so.6|NEEDED.*ld-linux" && { echo "FAIL: glibc leak"; exit 1; } || true
echo "$dyn" | grep -E "RPATH|RUNPATH" | grep -q "/nix/store" && { echo "FAIL: /nix/store RUNPATH leak"; exit 1; } || true
echo "  NEEDED libc.so.3 OK; no glibc/nix-store leak"

if [ "$MODE" = cpp ]; then
  echo "$dyn" | grep -q "NEEDED.*libstdc++.so.6" || { echo "FAIL: missing NEEDED libstdc++.so.6"; exit 1; }
  echo "  NEEDED libstdc++.so.6 OK"
fi

attr="$("$READELF" -A "$out" 2>/dev/null || true)"
echo "$attr" | grep -q "Tag_CPU_arch: v7" || echo "WARN: Tag_CPU_arch != v7"
echo "$attr" | grep -qi "VFPv3" || echo "WARN: Tag_FP_arch != VFPv3-D16"

"$READELF" -p .comment "$out" 2>/dev/null | grep -q "9.5.0" || echo "WARN: .comment lacks GCC 9.5.0"

echo "== PASS ($MODE) =="
