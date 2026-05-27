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
        # target tree is never committed and has NO default: it must be supplied
        # via the BBNIX_SYSROOT env var, which means package builds run impure,
        # e.g. `BBNIX_SYSROOT=/path/to/bbndk-linux nix build --impure .#gcc`.
        # An unset value throws at eval time rather than silently using a local
        # path. (Build-time reads of the sysroot are allowed via __noChroot;
        # --impure is needed only because getEnv is impure at eval time.)
        sysrootBase =
          let s = builtins.getEnv "BBNIX_SYSROOT"; in
          if s == "" then
            throw "bbnix: BBNIX_SYSROOT is not set. Point it at your bbndk-linux tree and build impurely, e.g.: BBNIX_SYSROOT=/path/to/bbndk-linux nix build --impure .#gcc"
          else s;

        qnxTarget = "arm-unknown-nto-qnx8.0.0eabi";

        # Canonical on-device install root for the deploy bundle. The tree is
        # relocatable (libs via LD_LIBRARY_PATH, CA via the launcher's
        # SSL_CERT_FILE/CURL_CA_BUNDLE), but a couple of paths are baked at build
        # time and want a fixed default: openssl's trust dir and curl's CA file.
        # Pointing them under this root means bare curl works when the bundle is
        # unpacked here, with no launcher env. Override at runtime as needed.
        installRoot = "/accounts/1000/shared/misc/bbnix";

        # The QNX target tree passed as --with-sysroot. Headers live under
        # <sysrootRoot>/usr/include; ARM libs/CRT under <sysrootRoot>/armle-v7/lib.
        sysrootRoot = "${sysrootBase}/target_10_3_1_995/qnx6";

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
        # zlib + openssl -> openssh; zlib + openssl -> curl.
        zlib-qnx = pkgs.callPackage ./pkgs/zlib.nix {
          inherit binutils gcc;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        openssl-qnx = pkgs.callPackage ./pkgs/openssl.nix {
          inherit binutils gcc;
          opensslDir = "${installRoot}/ssl";
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

        # HTTPS client over our from-source OpenSSL 3.x + zlib (issue #2). Static
        # libcurl.a for downstream partial-static linking, plus the curl CLI.
        curl = pkgs.callPackage ./pkgs/curl.nix {
          inherit binutils gcc;
          openssl = openssl-qnx;
          zlib = zlib-qnx;
          caBundle = "${installRoot}/ssl/cacert.pem";
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

        # tmux's event loop; static .a embedded into tmux (sole consumer).
        libevent-qnx = pkgs.callPackage ./pkgs/libevent.nix {
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

        # tmux: terminal multiplexer (libevent + ncursesw).
        tmux = pkgs.callPackage ./pkgs/tmux.nix {
          inherit binutils gcc;
          libevent = libevent-qnx;
          ncurses = ncurses-qnx;
          compat = qnx-compat;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # zsh: richer interactive shell (static single binary; ncursesw + iconv).
        zsh = pkgs.callPackage ./pkgs/zsh.nix {
          inherit binutils gcc;
          ncurses = ncurses-qnx;
          compat = qnx-compat;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # mosh-client: the Blink-style remote-dev endgame.
        mosh = pkgs.callPackage ./pkgs/mosh.nix {
          inherit binutils gcc protobuf-host;
          ncurses = ncurses-qnx;
          zlib = zlib-qnx;
          protobuf = protobuf-qnx;
          openssl = openssl-qnx;
          compat = qnx-compat;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # LD_PRELOAD crash tracer; deployed into the bundle's lib/ for diagnosing
        # the next C++ exception/RTTI ABI fault. The `mosh` launcher loads it
        # automatically when present.
        btcrash = pkgs.callPackage ./pkgs/btcrash.nix {
          inherit binutils gcc;
          target = qnxTarget;
          sysroot = sysrootRoot;
        };

        # Generic ELF trampoline for libexec shell sidecars (issue #6).
        sh-launcher = pkgs.callPackage ./pkgs/sh-launcher.nix {
          inherit binutils gcc;
          target = qnxTarget;
        };

        # Relocatable deploy bundle (issue #4): a bin/ + lib/ + terminfo/ + CA
        # tree Term50 pins as a flake input and stages under app/native/bbnix.
        # Variants nest minimal ⊂ ssh ⊂ full; .#deploy-bundle is the full set.
        mkBundle = variant: pkgs.callPackage ./pkgs/deploy-bundle.nix {
          inherit variant openssh curl mosh tmux zsh btcrash sh-launcher;
          ncurses = ncurses-qnx;
          openssl = openssl-qnx;
          zlib = zlib-qnx;
          compat = qnx-compat;
          cacert = pkgs.cacert;
        };
        deploy-bundle-minimal = mkBundle "minimal";
        deploy-bundle-ssh = mkBundle "ssh";
        deploy-bundle-full = mkBundle "full";
      in {
        # Recipes live under toolchain/ and pkgs/ and are wired in here as they
        # land. Sequence (see README): toolchain PoC -> ncurses -> openssh ->
        # tmux + mosh-client -> busybox subset.
        packages = {
          inherit binutils gcc-stage1 gcc openssh curl mosh tmux zsh btcrash sh-launcher;
          zlib = zlib-qnx;
          openssl = openssl-qnx;
          ncurses = ncurses-qnx;
          protobuf = protobuf-qnx;
          libevent = libevent-qnx;
          inherit qnx-compat protobuf-host;
          inherit deploy-bundle-minimal deploy-bundle-ssh deploy-bundle-full;
          deploy-bundle = deploy-bundle-full;
        };

        # Builds + validates the full bundle. Like every bbnix build this reads
        # the impure BBNIX_SYSROOT, so run `nix flake check --impure`. The whole
        # checks/ dir is staged so validate-bundle.sh finds its validate-elf.sh
        # sibling in the store.
        checks.deploy-bundle = pkgs.runCommand "validate-deploy-bundle"
          { nativeBuildInputs = [ pkgs.bash ]; } ''
          bash ${./checks}/validate-bundle.sh ${binutils} ${deploy-bundle-full}
          touch $out
        '';

        devShells.default = pkgs.mkShell {
          name = "bbnix";
          packages = with pkgs; [ gnumake file ];
          shellHook = ''
            export BBNIX_TARGET="${qnxTarget}"
            if [ -z "''${BBNIX_SYSROOT:-}" ]; then
              echo "bbnix: BBNIX_SYSROOT is unset — set it to your bbndk-linux tree before building (builds run with --impure)." >&2
            else
              echo "bbnix: target=$BBNIX_TARGET sysroot=$BBNIX_SYSROOT"
              [ -d "$BBNIX_SYSROOT" ] || echo "bbnix: warning: sysroot not found at $BBNIX_SYSROOT" >&2
            fi
          '';
        };
      });
}
