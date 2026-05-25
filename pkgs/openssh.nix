# SPDX-License-Identifier: MIT
# OpenSSH 10.0p2 cross-built from source for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM), client + sshd.
#
# Links our from-source OpenSSL 3.x + zlib 1.3.x (NEEDED .so.3 / .so.1), not the
# sysroot's EOL prebuilt .so.2 libs. autoconf cross-build: --host marks it cross
# so configure skips most run-tests, but a few probes that *run* a target binary
# need their results pre-seeded as ac_cv_* cache vars (we cannot run QNX ARM
# binaries on the build host).
{
  stdenv,
  lib,
  fetchurl,
  patchelf,
  binutils,
  gcc,
  openssl,
  zlib,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-openssh";
  version = "10.0p2";

  src = fetchurl {
    url = "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${version}.tar.gz";
    sha256 = "0p6qp47gkkjrxlqaignsvn81lh80wnlxasr5n5845pqfk9q2w6h2";
  };

  nativeBuildInputs = [ patchelf ];

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}

    # QNX has no <syslog.h> (it ships slog2), but libc.so.3 exports the BSD
    # syslog symbols -- provide the shared shim header so sshd's logging
    # compiles and links. See pkgs/files/syslog.h.
    mkdir -p shim
    cp ${./files/syslog.h} shim/syslog.h

    # -I our from-source openssl/zlib headers AHEAD of the sysroot's prebuilt
    # ones (which the cross gcc auto-searches); stddefFlag for the QNX
    # size_t/unistd.h gap (qnx-common.nix); LIBS=-lsocket because QNX
    # sockets/getaddrinfo live in libsocket.so.3, not libc.
    export CPPFLAGS="${qnx.stddefFlag} -I$PWD/shim -I${openssl}/include -I${zlib}/include"
    export LDFLAGS="-L${openssl}/lib -L${zlib}/lib"
    export LIBS="-lsocket"

    # Cross cache vars: these probes compile AND RUN a target binary to detect
    # broken implementations; we cannot run QNX ARM here, so assert the QNX
    # results directly. QNX libc has setreuid/setregid but NOT setresuid/
    # setresgid -- get these wrong and the link fails on undefined setres*id.
    export ac_cv_func_setresuid=no
    export ac_cv_func_setresgid=no
    export ac_cv_func_setreuid=yes
    export ac_cv_func_setregid=yes

    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --with-ssl-dir=${openssl} \
      --with-zlib=${zlib} \
      --without-pam \
      --without-selinux \
      --with-sandbox=no \
      --with-privsep-path=/var/empty \
      --with-privsep-user=sshd \
      --with-pid-dir=/var/run \
      --sysconfdir=/accounts/1000/shared/misc/etc/ssh
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  # install-nokeys installs all binaries but skips host-key generation, which
  # would try to RUN the cross-built ssh-keygen on the host. Keys are generated
  # on-device at deploy (ssh-keygen -A).
  installPhase = ''
    runHook preInstall
    # Drop the setuid mode (4711) on ssh-keysign/ssh-sk-helper: the Nix build
    # user can't set setuid bits in the store. These are only needed for
    # host-based auth / FIDO; if wanted, set setuid root at deploy on-device.
    sed -i 's/-m 4711/-m 0755/g' Makefile
    # STRIP_OPT= disables OpenSSH's `install -s`, which would run the host strip
    # on our ARM QNX ELFs ("Unable to recognise the architecture").
    #
    # install-files (binaries + manpages) only -- NOT install-nokeys, whose
    # install-sysconf step would try to mkdir the on-device --sysconfdir
    # (/accounts/...) on the build host. The binaries embed that path; we ship
    # the sample configs into $out/etc/ssh for the deploy step to copy there.
    make install-files STRIP_OPT=
    install -Dm644 sshd_config $out/etc/ssh/sshd_config
    install -Dm644 ssh_config  $out/etc/ssh/ssh_config
    runHook postInstall
  '';

  # Ship NO RPATH: the device's QNX loader does not expand $ORIGIN, so deploy
  # sets LD_LIBRARY_PATH=<libdir>. Strip any rpath the build baked in (notably
  # --with-ssl-dir can add a /nix/store path) so nothing leaks. $out/sbin is a
  # stdenv symlink to bin, so we iterate bin + libexec only (all ELF binaries).
  # See [[bbnix-openssh-userland]].
  postFixup = ''
    for f in $out/bin/* $out/libexec/*; do
      patchelf --remove-rpath "$f"
    done
  '';

  meta = {
    description = "OpenSSH ${version} (client + sshd) cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.bsd2;
    platforms = [ "x86_64-linux" ];
  };
})
