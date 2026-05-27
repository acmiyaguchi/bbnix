# SPDX-License-Identifier: MIT
# curl 8.20.0 cross-built from source for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM): static libcurl.a + the curl CLI.
#
# The point is an HTTPS client over bbnix's from-source OpenSSL 3.x + zlib,
# instead of the sysroot's prebuilt libcurl.so.2 -- which drags in BB10's EOL
# OpenSSL 1.0.x and its 2012-vintage CA store that can't path-build modern
# cross-signed chains. Over OpenSSL 3.x the trust store collapses to a single
# baked CA bundle and verification "just works".
#
# We emit a static libcurl.a (--disable-shared): downstreams link it
# partial-static (like liblua.a) and so escape the device's libcurl entirely.
# --without-gssapi is the specific unblock for static curl -- the device's
# libcurl.a needed shared-only krb5/gssapi; omitting it makes a static build
# possible. The remaining --without/--disable flags trim transitive deps we
# don't need; revisit individually if a consumer wants HTTP/2 etc.
#
# --with-ca-bundle bakes an on-device default path matching openssl.nix's
# --openssldir; the deploy bundle ships nixpkgs.cacert's cacert.pem there
# (<install-root>/ssl/cacert.pem), so bare curl verifies with no
# CURL_CA_BUNDLE/SSL_CERT_FILE wrapper once unpacked at that root.
#
# autoconf cross-build: --host marks it cross so configure skips most run-tests.
# LIBS=-lsocket because QNX sockets/getaddrinfo live in libsocket.so.3, not libc
# (same as openssh).
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
  # Compile-time default CA bundle path, baked via --with-ca-bundle. The flake
  # threads the deploy install root here so it lands at <root>/ssl/cacert.pem,
  # where the bundle stages cacert.pem. Only a default -- callers can override
  # at runtime (--cacert, CURLOPT_CAINFO, CURL_CA_BUNDLE).
  caBundle ? "/accounts/1000/shared/misc/bbnix/ssl/cacert.pem",
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-curl";
  version = "8.20.0";

  src = fetchurl {
    url = "https://curl.se/download/curl-${version}.tar.gz";
    sha256 = "1h1d7mcp74bdn2av658759nz659cg2dc9kddd4k4ixgrsg51jn7w";
  };

  nativeBuildInputs = [ patchelf ];

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}

    # -I our from-source openssl/zlib headers AHEAD of the sysroot's prebuilt
    # ones (which the cross gcc auto-searches); stddefFlag for the QNX
    # size_t/unistd.h gap (qnx-common.nix). LIBS=-lsocket because QNX
    # sockets/getaddrinfo live in libsocket.so.3, not libc.
    export CPPFLAGS="${qnx.stddefFlag} -I${openssl}/include -I${zlib}/include"
    export LDFLAGS="-L${openssl}/lib -L${zlib}/lib"
    export LIBS="-lsocket"

    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --with-openssl=${openssl} \
      --with-zlib=${zlib} \
      --with-ca-bundle=${caBundle} \
      --without-gssapi \
      --disable-ldap --disable-ldaps \
      --without-nghttp2 --without-libpsl --without-brotli --without-zstd \
      --disable-shared --enable-static \
      --disable-manual --disable-docs
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
  # sets LD_LIBRARY_PATH=<libdir>. Strip any rpath the build baked in (the
  # --with-openssl/--with-zlib dirs can add /nix/store paths) so nothing leaks.
  # libcurl.a is static and needs no fixup. See [[bbnix-openssh-userland]].
  postFixup = ''
    patchelf --remove-rpath $out/bin/curl
  '';

  meta = {
    description = "curl ${version} (static libcurl + CLI) cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.curl;
    platforms = [ "x86_64-linux" ];
  };
})
