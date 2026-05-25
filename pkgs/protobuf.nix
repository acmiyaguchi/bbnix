# SPDX-License-Identifier: MIT
# protobuf 3.6.1 runtime library cross-built from source for
# arm-unknown-nto-qnx8.0.0eabi (BlackBerry 10 / QNX 8 ARM).
#
# mosh's state-sync protocol is .proto-defined, so it needs libprotobuf on the
# target plus a host protoc to generate the .pb.{cc,h} (pkgs/protobuf-host.nix,
# same 3.6.1 -- the generated code is version-locked to the runtime). We build
# the library STATIC (.a): mosh embeds it, so there is no extra .so to deploy
# and no soname/$ORIGIN concern. protobuf 3.6.1 still ships autotools, which is
# why this version is cross-buildable at all (later releases are CMake/Bazel).
{
  stdenv,
  lib,
  fetchurl,
  binutils,
  gcc,
  protobuf-host,
  compat,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-protobuf";
  version = "3.6.1";

  src = fetchurl {
    url = "https://github.com/protocolbuffers/protobuf/releases/download/v${version}/protobuf-cpp-${version}.tar.gz";
    sha256 = "0a955bz59ihrb5wg7dwi12xajdi5pmz4bl0g147rbdwv393jwwxk";
  };

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}
    export CXX=${gcc}/bin/${target}-g++

    # Empty libpthread stub: protobuf's ACX_PTHREAD probe links -lpthread, but
    # QNX has no separate libpthread (pthreads live in libc). With the symbols
    # already in libc, an empty archive satisfies the -lpthread flag. (Same
    # trick openssl.nix uses for -ldl.)
    mkdir -p stublib
    ${binutils}/bin/${target}-ar crs stublib/libpthread.a

    # cstdintFlag/cxxAbiFlags: the QNX std::size_t gap and the C++14 sized-delete
    # gap over libstdc++ 4.8.3 (qnx-common). protobuf is what first surfaced both
    # -- its bytestream.h includes a plain C <stddef.h> before any STL header.
    # libbbnixcompat supplies the other 4.9-era ABI gap
    # (__cxa_throw_bad_array_new_length) -- link it so a shared build resolves it
    # (a static .a defers it to the mosh link, where compat is also present).
    export CXXFLAGS="${qnx.cstdintFlag} ${qnx.cxxAbiFlags}"
    export LDFLAGS="-L$PWD/stublib -L${compat}/lib -lbbnixcompat"

    # --with-protoc: use the prebuilt host protoc to compile the bundled
    # descriptors; the cross-built protoc could not run here. --without-zlib:
    # mosh does not use protobuf's optional Gzip streams. Static only.
    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --with-protoc=${protobuf-host}/bin/protoc \
      --without-zlib \
      --disable-shared --enable-static
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
    description = "protobuf ${version} runtime (static) cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
})
