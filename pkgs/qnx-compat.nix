# SPDX-License-Identifier: MIT
# libbbnixcompat: a small shared library supplying POSIX/C functions that
# QNX 8 / BB10's libc is missing (tsearch(3) family, wcwidth/wcswidth). Linked
# ahead of libc by recipes that need them (ncurses widec, mosh). The symbols
# are the plain libc names, so they satisfy undefined references directly.
# See pkgs/files/qnx-compat.c for the per-function rationale.
{
  stdenv,
  lib,
  patchelf,
  binutils,
  gcc,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // {
  pname = "bbnix-compat";
  version = "1";

  dontUnpack = true;
  nativeBuildInputs = [ patchelf ];

  buildPhase = ''
    runHook preBuild
    ${qnx.crossEnv}
    $CC -shared -fPIC ${qnx.stddefFlag} -Wl,-soname,libbbnixcompat.so.1 \
      -o libbbnixcompat.so.1 ${./files/qnx-compat.c}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libbbnixcompat.so.1 $out/lib/libbbnixcompat.so.1
    ln -s libbbnixcompat.so.1 $out/lib/libbbnixcompat.so
    runHook postInstall
  '';

  # Ship NO RPATH (device loader has no $ORIGIN); deploy via LD_LIBRARY_PATH.
  postFixup = ''
    patchelf --remove-rpath $out/lib/libbbnixcompat.so.1
  '';

  meta = {
    description = "QNX libc compat shim (tsearch family, wcwidth) for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
})
