# Cross binutils for arm-unknown-nto-qnx8.0.0eabi (BlackBerry 10 / QNX 8 ARM).
#
# Mainline binutils 2.41 already supports the triple with no patches:
#   bfd/config.bfd     arm-*-nto*  -> arm_elf32_le_vec
#   ld/configure.tgt   arm-*-nto*  -> armnto  (ld/emulparams/armnto.sh)
#   config.sub         canonicalizes arm-unknown-nto-qnx8.0.0eabi
#
# binutils needs no target libc to build, so --with-sysroot only records the
# path; this derivation stays pure/sandboxed (no proprietary bytes required).
{
  stdenv,
  fetchurl,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  # Sysroot path is recorded into binutils' default search root. Passed as a
  # plain string (Model A); its contents are not read at build time.
  sysroot,
}:

stdenv.mkDerivation rec {
  pname = "bbnix-binutils";
  version = "2.41";

  src = fetchurl {
    url = "https://ftpmirror.gnu.org/binutils/binutils-${version}.tar.xz";
    sha256 = "0l3l003dynq11ppr2h8p0cfc7zyky8ilfwg60sbfan9lwa4mg6mf";
  };

  # texinfo/file pulled in by stdenv; bison/flex not needed for a release tarball.
  depsBuildBuild = [ ];

  configurePlatforms = [ ];

  configureFlags = [
    "--target=${target}"
    "--with-sysroot=${sysroot}"
    "--disable-nls"
    "--disable-shared"
    "--disable-werror"
    "--disable-initfini-array"
    # Trim things we don't use on QNX/BB10; keep bfd ld + gas.
    "--disable-gdb"
    "--disable-gprofng"
  ];

  enableParallelBuilding = true;

  # The info docs occasionally trip release tarballs; we don't need them.
  postPatch = ''
    export MAKEINFO=true
  '';

  meta = {
    description = "GNU binutils cross-targeting BlackBerry 10 / QNX 8 ARM (${target})";
    platforms = [ "x86_64-linux" ];
  };
}
