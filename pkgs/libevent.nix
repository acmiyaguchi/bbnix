# SPDX-License-Identifier: MIT
# libevent 2.1.12-stable cross-built from source for
# arm-unknown-nto-qnx8.0.0eabi (BlackBerry 10 / QNX 8 ARM).
#
# tmux's only hard dependency: its whole event loop is libevent. We build it
# STATIC (.a) -- tmux is the sole consumer, so embedding it means no extra .so
# to deploy and no soname/LD_LIBRARY_PATH concern (cf. protobuf for mosh).
#
# QNX has no epoll/kqueue; libevent's configure falls back to its poll/select
# backends (both fully supported by QNX libc), so no backend coaxing is needed.
{
  stdenv,
  lib,
  fetchurl,
  binutils,
  gcc,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-libevent";
  version = "2.1.12-stable";

  src = fetchurl {
    url = "https://github.com/libevent/libevent/releases/download/release-${version}/libevent-${version}.tar.gz";
    sha256 = "1fq30imk8zd26x8066di3kpc5zyfc5z6frr3zll685zcx4dxxrlj";
  };

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}

    # QNX has no <syslog.h> (it ships slog2), but libc.so.3 exports the BSD
    # syslog symbols libevent's http.c logs through -- drop in the shared shim.
    # See pkgs/files/syslog.h.
    mkdir -p shim
    cp ${./files/syslog.h} shim/syslog.h

    # stddefFlag / saRestartFlag: the QNX size_t/unistd.h cross gap and the
    # missing SA_RESTART (qnx-common.nix). libevent's event loop uses sockets
    # (evutil, evdns); on QNX those live in libsocket, not libc, so every link
    # that pulls a socket call needs -lsocket. The .a we produce records no
    # NEEDED, so this LDFLAGS only matters for configure's link probes -- tmux
    # re-supplies -lsocket at the final link.
    export CFLAGS="${qnx.stddefFlag} ${qnx.saRestartFlag}"
    export CPPFLAGS="${qnx.stddefFlag} -I$PWD/shim"
    export LDFLAGS="-lsocket"

    # --disable-openssl/mbedtls: tmux uses none of libevent's TLS bufferevents,
    # so we avoid pulling our from-source OpenSSL into this leaf. --disable-shared:
    # static only (see header). regress/samples build test/demo programs that
    # would be cross-built and never run -- skip them.
    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --disable-shared --enable-static \
      --disable-openssl --disable-mbedtls \
      --disable-libevent-regress --disable-samples \
      --disable-debug-mode
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install
    runHook postInstall
  '';

  meta = {
    description = "libevent ${version} (static) cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
})
