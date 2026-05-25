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

    # QNX size_t gap, C++ flavour. QNX's stddef.h defines std::size_t only via a
    # fragile _STD_USING dance: if a plain C <stddef.h> is seen before std::size_t
    # exists (protobuf's bytestream.h does exactly this), a later `using
    # std::size_t` inside that header fails ("std::size_t not declared"). Force
    # <cstdint> first: it pulls libstdc++'s <bits/c++config.h>, which defines
    # std::size_t/std::ptrdiff_t straight from compiler builtins, so the QNX
    # header's using-declaration always resolves (and it supplies the std::int*_t
    # protobuf wants). The C prologue `-include stddef.h` instead *breaks* C++.
    #
    # CXXFLAGS (not CPPFLAGS): cstdint is C++-only, and configure feeds CPPFLAGS
    # to its C compiler probe too ("C compiler cannot create executables").
    # cxxAbiFlags (-fno-sized-deallocation): GCC 9 emits the C++14 sized
    # operator delete, absent from libstdc++ 4.8.3 (qnx-common). libbbnixcompat
    # supplies the other 4.9-era ABI gap (__cxa_throw_bad_array_new_length) --
    # link it so a shared build resolves it (a static .a defers it to the mosh
    # link, where compat is also present).
    export CXXFLAGS="-include cstdint ${qnx.cxxAbiFlags}"
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
