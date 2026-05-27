# SPDX-License-Identifier: MIT
# sh-launcher: a generic ELF trampoline for shell-script tools in the bbnix bundle.
#
# The BB10 packaging path strips a script's execute bit and the on-device
# installer only restores +x on ELF files, so a `#!/bin/sh` launcher can never
# run under the read-only app/native image. This tiny ELF is the executable
# entry point the installer will mark +x; it execs `/bin/sh` on the real shell
# logic kept as a non-executable libexec/ sidecar. See pkgs/files/sh-launcher.c
# and issue #6. Convention: installed as bin/<tool>, it execs <root>/libexec/<tool>.
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
  pname = "bbnix-sh-launcher";
  version = "1";

  dontUnpack = true;
  nativeBuildInputs = [ patchelf ];

  buildPhase = ''
    runHook preBuild
    ${qnx.crossEnv}
    # stddefFlag: QNX's <unistd.h> skips the size_t typedef without <stddef.h>
    # first. See [[qnx-unistd-size-t-stddef-gap]].
    $CC ${qnx.stddefFlag} -O2 -Wall -o sh-launcher ${./files}/sh-launcher.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 sh-launcher $out/bin/sh-launcher
    runHook postInstall
  '';

  # Ship NO RPATH (device loader has no $ORIGIN); links only the device libc,
  # which is on the default loader path.
  postFixup = ''
    patchelf --remove-rpath $out/bin/sh-launcher
  '';

  meta = {
    description = "Generic ELF sh-trampoline for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
})
