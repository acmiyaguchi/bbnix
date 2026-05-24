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
      in {
        # Recipes live under toolchain/ and pkgs/ and are wired in here as they
        # land. Sequence (see README): toolchain PoC -> ncurses -> openssh ->
        # tmux + mosh-client -> busybox subset.
        packages = { };

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
