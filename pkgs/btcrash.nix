# SPDX-License-Identifier: MIT
# libbtcrash: an LD_PRELOAD crash tracer for the bbnix userland on QNX 8 / BB10.
#
# On a fatal signal it prints the fault address, the faulting PC/LR (from the
# signal ucontext) and the process memory map (cached at startup from
# /proc/self/as, so it survives ASLR), then re-raises the default action.
# Offline: map the PC back to an ELF via region [vaddr,vaddr+size) + offset and
# addr2line it. Built the diagnosis of the mosh roaming SIGSEGV; kept for the
# next C++ exception/RTTI ABI landmine. See [[bbnix-cxx-exception-abi-crash]].
#
# The `mosh` launcher LD_PRELOADs this automatically when $root/lib/libbtcrash.so
# is present, so deploy it into the bundle's lib/ alongside the other .so's.
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
  pname = "bbnix-btcrash";
  version = "1";

  dontUnpack = true;
  nativeBuildInputs = [ patchelf ];

  buildPhase = ''
    runHook preBuild
    ${qnx.crossEnv}
    # gnu99 for the C99 decls-in-loop the tracer uses; the QNX procfs/ucontext
    # headers (devctl.h, sys/procfs.h, arm/context.h) come from the sysroot.
    $CC -shared -fPIC -std=gnu99 ${qnx.stddefFlag} -Wl,-soname,libbtcrash.so \
      -o libbtcrash.so ${./files}/btcrash.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 libbtcrash.so $out/lib/libbtcrash.so
    runHook postInstall
  '';

  # Ship NO RPATH (device loader has no $ORIGIN); deploy via LD_LIBRARY_PATH.
  postFixup = ''
    patchelf --remove-rpath $out/lib/libbtcrash.so
  '';

  meta = {
    description = "LD_PRELOAD crash tracer for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
})
