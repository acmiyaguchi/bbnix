# SPDX-License-Identifier: MIT
# zlib 1.3.1 cross-built from source for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM).
#
# We build zlib from source rather than using the sysroot's prebuilt libz.so.2
# (zlib 1.2.8, 2013) so the network stack rides modern code. Soname is
# libz.so.1 -- distinct from the sysroot's .so.2, so NEEDED is unambiguous.
#
# zlib's ./configure is a hand-written shell script, NOT autoconf: it honors
# CC/AR/RANLIB/CHOST from the environment and rejects the autoconf flag set
# stdenv's default configurePhase would pass. So we drive it explicitly. The
# cross gcc bakes --with-sysroot, so it finds libc/CRT under the sysroot itself.
{
  stdenv,
  lib,
  fetchurl,
  patchelf,
  binutils,
  gcc,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  # Recorded for symmetry with the other recipes; the cross gcc already knows
  # the sysroot, so zlib needs no explicit reference to it.
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-zlib";
  version = "1.3.1";

  src = fetchurl {
    url = "https://zlib.net/fossils/zlib-${version}.tar.gz";
    sha256 = "08yzf8xz0q7vxs8mnn74xmpxsrs6wy0aan55lpmpriysvyvv54ws";
  };

  nativeBuildInputs = [ patchelf ];

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}
    export CHOST=${target}
    export CFLAGS="${qnx.stddefFlag}"
    ./configure --prefix=$out --shared
    runHook postConfigure
  '';

  # zlib's configure does not apply -Wl,-soname for our unknown CHOST, so the
  # .so ships without DT_SONAME and anything linking -lz records the bare link
  # name (libz.so) as NEEDED instead of the versioned soname. Set the soname
  # explicitly. We ship NO RPATH: the device's QNX loader does not expand
  # $ORIGIN, so deploy sets LD_LIBRARY_PATH=<libdir>. See [[bbnix-openssh-userland]].
  postFixup = ''
    lib=$out/lib/libz.so.${version}
    patchelf --set-soname libz.so.1 "$lib"
    patchelf --remove-rpath "$lib"
  '';

  meta = {
    description = "zlib ${version} cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.zlib;
    platforms = [ "x86_64-linux" ];
  };
})
