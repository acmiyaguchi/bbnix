# SPDX-License-Identifier: MIT
# Shared cross-build scaffolding for the bbnix userland recipes (pkgs/).
#
# The toolchain recipes (toolchain/*.nix) inline their config -- there are only
# two. The userland set is larger and growing (zlib, openssl, openssh, then
# ncurses/tmux/mosh/busybox), and every recipe repeats the same QNX cross
# conventions, so they share them here. Use from a recipe with:
#
#   qnx = import ./qnx-common.nix { inherit gcc binutils target; };
#   stdenv.mkDerivation (qnx.drvAttrs // rec { ... });
{ gcc, binutils, target }:
{
  # mkDerivation attrs common to every QNX userland cross build.
  drvAttrs = {
    __noChroot = true;            # read the impure BYO sysroot in place (Model A)
    dontStrip = true;             # the host strip can't touch ARM QNX ELFs
    dontPatchELF = true;          # we set RUNPATH ourselves; stdenv's shrink would leak store paths
    enableParallelBuilding = true;
  };

  # Point the build at the cross toolchain. The cross gcc bakes --with-sysroot,
  # so it finds the sysroot's headers/CRT automatically; binutils supplies the
  # target-prefixed ar/ranlib.
  crossEnv = ''
    export CC=${gcc}/bin/${target}-gcc
    export AR=${binutils}/bin/${target}-ar
    export RANLIB=${binutils}/bin/${target}-ranlib
  '';

  # QNX cross prologue. QNX's <sys/compiler_gnu.h> predefines _GCC_SIZE_T, which
  # makes both GCC's <stddef.h> and <unistd.h>'s own fallback decline to typedef
  # size_t -- yet nothing in the <unistd.h> include chain pulls <stddef.h> in, so
  # a plain `#include <unistd.h>` fails with "unknown type name 'size_t'". Force
  # <stddef.h> first. See [[qnx-unistd-size-t-stddef-gap]].
  stddefFlag = "-include stddef.h";
}
