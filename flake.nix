# SPDX-License-Identifier: MIT
{
  description = "bbnix — a minimal, from-source cross-build userland for BlackBerry 10 / QNX 8 (armle-v7)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # BYO sysroot (Model A — impure path). The proprietary QNX 8 / BB10
        # target tree is never committed; it is referenced in place from the
        # bbdev workspace, mirroring how the workspace flake references sdkDir.
        # Override with: nix develop --override-input ... or BBNIX_SYSROOT.
        defaultSysroot = "/mnt/data/fun/bbdev/sdk/bbndk-linux";

        qnxTarget = "arm-unknown-nto-qnx8.0.0eabi";

        # The QNX target tree passed as --with-sysroot. Headers live under
        # <sysrootRoot>/usr/include; ARM libs/CRT under <sysrootRoot>/armle-v7/lib.
        sysrootRoot = "${defaultSysroot}/target_10_3_1_995/qnx6";

        binutils = pkgs.callPackage ./toolchain/binutils.nix {
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # Stage 1: C-only cross-compiler (libgcc) for milestones M1/M2.
        gcc-stage1 = pkgs.callPackage ./toolchain/gcc.nix {
          inherit binutils;
          target = qnxTarget;
          sysroot = sysrootRoot;
          langCxx = false;
        };

        # Full C/C++ cross-compiler for milestone M3. We build cc1plus + libgcc
        # but reuse the sysroot's own libstdc++ 4.8.3 (headers + armle-v7 .so)
        # rather than rebuilding GCC 9's against QNX's Dinkumware headers --
        # matching the device ABI and avoiding the _STD_USING namespace war.
        gcc = pkgs.callPackage ./toolchain/gcc.nix {
          inherit binutils;
          target = qnxTarget;
          sysroot = sysrootRoot;
          langCxx = true;
          gxxIncludeDir = "${sysrootRoot}/usr/include/c++/4.8.3";
        };

        # Userland recipes (pkgs/), cross-built with the toolchain above against
        # the BYO sysroot. Suffixed -qnx where the bare name would collide with a
        # host nixpkgs attr (pkgs.zlib is consumed by gcc.nix). Dependency chain:
        # zlib + openssl -> openssh.
        zlib-qnx = pkgs.callPackage ./pkgs/zlib.nix {
          inherit binutils gcc;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        openssl-qnx = pkgs.callPackage ./pkgs/openssl.nix {
          inherit binutils gcc;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        openssh = pkgs.callPackage ./pkgs/openssh.nix {
          inherit binutils gcc;
          openssl = openssl-qnx;
          zlib = zlib-qnx;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # Native protoc 3.6.1 (build host) that drives the cross libprotobuf.
        protobuf-host = pkgs.callPackage ./pkgs/protobuf-host.nix { };

        # Cross-built static libprotobuf 3.6.1 (mosh's state-sync protocol).
        protobuf-qnx = pkgs.callPackage ./pkgs/protobuf.nix {
          inherit binutils gcc protobuf-host;
          compat = qnx-compat;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # Fills QNX libc gaps (tsearch family, wcwidth) that ncurses/mosh hit.
        qnx-compat = pkgs.callPackage ./pkgs/qnx-compat.nix {
          inherit binutils gcc;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # Step 3 (tmux + mosh-client): ncurses is the shared TUI dependency.
        ncurses-qnx = pkgs.callPackage ./pkgs/ncurses.nix {
          inherit binutils gcc;
          compat = qnx-compat;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };
      in {
        # Recipes live under toolchain/ and pkgs/ and are wired in here as they
        # land. Sequence (see README): toolchain PoC -> ncurses -> openssh ->
        # tmux + mosh-client -> busybox subset.
        packages = {
          inherit binutils gcc-stage1 gcc openssh;
          zlib = zlib-qnx;
          openssl = openssl-qnx;
          ncurses = ncurses-qnx;
          protobuf = protobuf-qnx;
          inherit qnx-compat protobuf-host;
        };

        devShells.default = pkgs.mkShell {
          name = "bbnix";
          packages = with pkgs; [ gnumake file ];
          shellHook = ''
            export BBNIX_SYSROOT="''${BBNIX_SYSROOT:-${defaultSysroot}}"
            export BBNIX_TARGET="${qnxTarget}"
            echo "bbnix: target=$BBNIX_TARGET sysroot=$BBNIX_SYSROOT"
            if [ ! -d "$BBNIX_SYSROOT" ]; then
              echo "bbnix: warning: sysroot not found at $BBNIX_SYSROOT" >&2
            fi
          '';
        };
      });
}
