# SPDX-License-Identifier: MIT
# mosh 1.4.0 (mosh-client) cross-built from source for
# arm-unknown-nto-qnx8.0.0eabi (BlackBerry 10 / QNX 8 ARM).
#
# The Blink-style remote-dev endgame: the device runs mosh-client and dials out
# to a real Linux box's mosh-server. We build the client only (--enable-server=no);
# the server's forkpty/utmp path is a separate QNX experiment.
#
# Dependencies, all from bbnix: ncurses (terminal), zlib (transport compression),
# protobuf (state-sync protocol; static .a embedded), OpenSSL (mosh 1.4 is no
# longer self-contained -- it needs a crypto library's AES, here OpenSSL with
# mosh's internal OCB), and libbbnixcompat (wcwidth + the C++ ABI symbol the
# 4.8.3 runtime lacks). The host protoc generates the .pb.{cc,h}.
{
  stdenv,
  lib,
  fetchurl,
  pkg-config,
  perl,
  patchelf,
  binutils,
  gcc,
  ncurses,
  zlib,
  protobuf,
  openssl,
  protobuf-host,
  compat,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-mosh";
  version = "1.4.0";

  src = fetchurl {
    url = "https://github.com/mobile-shell/mosh/releases/download/mosh-${version}/mosh-${version}.tar.gz";
    sha256 = "1pax8sqlvcc7ammsxd9r53yx4m2hg1827wfz6f4rrwjx9q9lnbl7";
  };

  # pkg-config is still needed for the optional Nettle/bash-completion probes
  # (we feed the required modules' flags directly, below). perl only does a
  # build-time syntax check of the `mosh` launcher wrapper -- on-device we
  # invoke the mosh-client binary directly.
  nativeBuildInputs = [ pkg-config perl patchelf ];

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}
    export CXX=${gcc}/bin/${target}-g++
    # Host protoc generates mosh's .proto -> .pb.{cc,h} (cannot run the cross one).
    export PROTOC=${protobuf-host}/bin/protoc

    # QNX has no <langinfo.h>; mosh needs nl_langinfo(CODESET). Drop in the shim
    # header (libbbnixcompat supplies the symbol). See pkgs/files/langinfo.h.
    mkdir -p shim
    cp ${./files/langinfo.h} shim/langinfo.h
    cp ${./files/wcwidth_compat.h} shim/wcwidth_compat.h

    # Feed each PKG_CHECK_MODULES its flags directly so the macro skips the
    # pkg-config query -- our cross .pc files aren't on a sysroot pkg-config
    # path, and bypassing avoids the whole cross-pkg-config dance. (Nettle and
    # bash-completion are left to pkg-config; both are optional/absent.)
    export TINFO_CFLAGS="-I${ncurses}/include"
    export TINFO_LIBS="-L${ncurses}/lib -lncursesw"
    export protobuf_CFLAGS="-I${protobuf}/include"
    export protobuf_LIBS="-L${protobuf}/lib -lprotobuf"
    export OpenSSL_CFLAGS="-I${openssl}/include"
    export OpenSSL_LIBS="-L${openssl}/lib -lssl"

    # C++ over libstdc++ 4.8.3: -include cstdint fixes the QNX std::size_t gap
    # (see protobuf.nix) and cxxAbiFlags drops the C++14 sized delete.
    # -include wcwidth_compat.h: QNX's <wchar.h> declares no wcwidth, which C++
    # rejects (terminal.cc calls it). cstdint fixes the std::size_t gap (see
    # protobuf.nix); cxxAbiFlags drops the C++14 sized delete.
    export CXXFLAGS="-include cstdint -include wcwidth_compat.h ${qnx.cxxAbiFlags}"
    # zlib.h for the C/C++ probes; all dependency -L on the link path (AC_CHECK_LIB
    # for -lz/-lcrypto link-tests, and the final exe). LIBS pulls libbbnixcompat
    # (wcwidth + __cxa_throw_bad_array_new_length) after the referencing objects.
    export CPPFLAGS="-I$PWD/shim -I${zlib}/include"
    export LDFLAGS="-L${zlib}/lib -L${openssl}/lib -L${compat}/lib"
    export LIBS="-lbbnixcompat"

    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --enable-client=yes \
      --enable-server=no \
      --with-crypto-library=openssl \
      --without-utempter \
      --disable-completion \
      --disable-examples \
      --disable-hardening \
      --enable-compile-warnings=no
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

  # Ship NO RPATH: the device's QNX loader does not expand $ORIGIN, so deploy
  # sets LD_LIBRARY_PATH=<libdir>. See [[bbnix-openssh-userland]].
  postFixup = ''
    patchelf --remove-rpath $out/bin/mosh-client
  '';

  meta = {
    description = "mosh ${version} client cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
})
