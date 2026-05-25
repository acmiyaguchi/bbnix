# SPDX-License-Identifier: MIT
# Native (build-host) protobuf 3.6.1 -- we only want its `protoc`.
#
# Cross-building libprotobuf for QNX needs a protoc that RUNS on the build host
# to compile the bundled .proto descriptors (and, later, mosh's .proto files).
# The generated code is version-locked to the runtime library, so this MUST be
# the same 3.6.1 as pkgs/protobuf.nix (the cross runtime). This derivation is
# an ordinary native build; the cross recipe consumes ${this}/bin/protoc via
# --with-protoc. See pkgs/protobuf.nix.
{
  stdenv,
  lib,
  fetchurl,
}:

stdenv.mkDerivation rec {
  pname = "protobuf-host";
  version = "3.6.1";

  src = fetchurl {
    url = "https://github.com/protocolbuffers/protobuf/releases/download/v${version}/protobuf-cpp-${version}.tar.gz";
    sha256 = "0a955bz59ihrb5wg7dwi12xajdi5pmz4bl0g147rbdwv393jwwxk";
  };

  # protobuf 3.6.1 predates the stricter headers of modern GCC: it relies on
  # transitive <cstdint> for the fixed-width int types. Force-include it so the
  # current host compiler accepts the 2018 source.
  env.CXXFLAGS = "-include cstdint -std=gnu++14";

  enableParallelBuilding = true;

  meta = {
    description = "protobuf ${version} protoc for the build host (drives the QNX cross build)";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
}
