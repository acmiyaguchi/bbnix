# SPDX-License-Identifier: MIT
# OpenSSL 3.5.4 cross-built from source for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM).
#
# We build modern OpenSSL 3.x rather than linking the sysroot's prebuilt
# libcrypto.so.2 (1.0.1i, 2014, EOL) -- this is the point of bbnix: harden the
# network daemons. Soname is .so.3 (vs the sysroot's .so.2), so NEEDED is
# unambiguous and the from-source libs deploy alongside the binaries.
#
# OpenSSL has NO QNX target in Configure. We use the portable pure-C build-rule
# template `linux-generic32` (the "linux" names the ruleset, not OS feature use)
# with no-asm, and wire the cross tools via explicit CC/AR/RANLIB rather than
# --cross-compile-prefix (cleaner with our split binutils/gcc prefixes).
{
  stdenv,
  lib,
  fetchurl,
  patchelf,
  perl,
  binutils,
  gcc,
  # On-device trust dir baked as --openssldir; its cacert.pem is curl.nix's
  # default CA bundle. The flake points this under the deploy install root.
  opensslDir ? "/accounts/1000/shared/misc/ssl",
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-openssl";
  version = "3.5.4";

  src = fetchurl {
    url = "https://github.com/openssl/openssl/releases/download/openssl-${version}/openssl-${version}.tar.gz";
    sha256 = "16ay6ppxsky3qhg6573370iz93kihfwx9n5ipmlnjcam97w12wwn";
  };

  # perl drives OpenSSL's Configure + build; patchelf sets the deploy RUNPATH.
  nativeBuildInputs = [ perl patchelf ];

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}
    # syslog.h shim: QNX ships slog2 (<sys/slog2.h>), not BSD <syslog.h>.
    # OpenSSL's apps/lib (http_server.c, log.c) #include <syslog.h> and is
    # *compiled* even by `build_libs`, though never linked into the libs we
    # keep. The shared shim header (also used by openssh) lets those objects
    # compile. See pkgs/files/syslog.h.
    mkdir -p shim
    cp ${./files/syslog.h} shim/syslog.h
    # Empty libdl stub: the linux-generic32 target appends -ldl, but QNX has no
    # separate libdl (dlopen/dlsym live in libc). With no-dso nothing references
    # dl*, so an empty archive satisfies the -ldl flag without pulling symbols.
    mkdir -p stublib
    ${binutils}/bin/${target}-ar crs stublib/libdl.a

    # stddefFlag: QNX size_t/unistd.h cross gap (see qnx-common.nix). OpenSSL
    # honors CPPFLAGS from the env.
    export CPPFLAGS="${qnx.stddefFlag} -I$PWD/shim"
    export LDFLAGS="-L$PWD/stublib"
    # linux-generic32: portable C, no platform asm/syscalls baked in.
    #   no-asm    : avoid Linux/ELF assembler idioms (no perf need on a dev tool)
    #   no-tests  : the test harness compiles target binaries we cannot run
    #   no-engine no-dso : avoid dlfcn Linux-isms; we need no loadable engines
    #   no-async  : QNX has <ucontext.h> but no lib implements get/make/setcontext
    #               (deprecated on QNX); no-async uses the null stub instead
    #   threads   : QNX has POSIX pthreads in libc
    #   -lsocket  : QNX sockets/getaddrinfo live in libsocket.so.3, not libc
    perl ./Configure linux-generic32 \
      --prefix=$out \
      --libdir=lib \
      --openssldir=${opensslDir} \
      no-asm no-tests no-engine no-dso no-async threads \
      -lsocket
    runHook postConfigure
  '';

  # build_libs only: libcrypto.so.3 + libssl.so.3 (+ static). We deliberately
  # skip the `openssl` CLI app -- it pulls <syslog.h>, which QNX does not ship
  # (QNX uses slog2 / <sys/slog2.h> instead). OpenSSH needs only the libraries,
  # so porting the app's logging to slog2 is not worth it here.
  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES build_libs
    runHook postBuild
  '';

  # install_dev installs headers + static/shared libs + pkgconfig (no apps).
  installPhase = ''
    runHook preInstall
    make install_dev
    runHook postInstall
  '';

  # Ship NO RPATH: the device's QNX loader does not expand $ORIGIN, so deploy
  # sets LD_LIBRARY_PATH=<libdir> (which also lets libssl find libcrypto).
  # Strip any rpath the build baked in so no /nix/store path leaks.
  # See [[bbnix-openssh-userland]].
  postFixup = ''
    patchelf --remove-rpath $out/lib/libcrypto.so.3 $out/lib/libssl.so.3
  '';

  meta = {
    description = "OpenSSL ${version} cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
})
