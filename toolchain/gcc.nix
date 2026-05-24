# Forward-ported GCC 9 cross-compiler for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM).
#
# GCC 9 mainline has no ARM-QNX target; this derivation vendors the QNX target
# config from the BlackBerry/QNX GCC 4.9 fork (adapted in ./files/gcc9) and adds
# the arm*-*-nto-qnx* cases to config.gcc + libgcc/config.host
# (./patches/gcc9-arm-nto-core.patch).
#
# Model A (impure sysroot): the proprietary QNX target tree is read in place via
# __noChroot. Build with:  nix build --option sandbox relaxed .#gcc
#
# Staged: langCxx=false builds a C-only stage1 (libgcc only) -> milestones M1/M2.
#         langCxx=true additionally builds GCC's own libstdc++ -> milestone M3.
{
  stdenv,
  fetchurl,
  gmp,
  mpfr,
  libmpc,
  isl,
  zlib,
  flex,
  bison,
  texinfo,
  perl,
  binutils,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
  version ? "9.5.0",
  langCxx ? false,
}:

stdenv.mkDerivation {
  pname = "bbnix-gcc" + (if langCxx then "" else "-stage1");
  inherit version;

  src = fetchurl {
    url = "https://ftpmirror.gnu.org/gcc/gcc-${version}/gcc-${version}.tar.xz";
    sha256 = "13ygjmd938m0wmy946pxdhz9i1wq7z4w10l6pvidak0xxxj9yxi7";
  };

  # binutils on PATH supplies the target-prefixed ar/ranlib/nm/strip that the
  # libgcc/libstdc++ build invokes (as/ld are also wired via --with-as/--with-ld).
  nativeBuildInputs = [ flex bison texinfo perl binutils ];
  buildInputs = [ gmp mpfr libmpc isl zlib ];

  patches = [ ./patches/gcc9-arm-nto-core.patch ];

  # Drop the vendored QNX target headers/options into the tree.
  postPatch = ''
    cp ${./files/gcc9}/nto.h          gcc/config/nto.h
    cp ${./files/gcc9}/nto.opt        gcc/config/nto.opt
    cp ${./files/gcc9}/nto-stdint.h   gcc/config/nto-stdint.h
    cp ${./files/gcc9}/arm/nto-eabi.h gcc/config/arm/nto-eabi.h
    cp ${./files/gcc9}/arm/nto.opt    gcc/config/arm/nto.opt
    cp ${./files/gcc9}/arm/t-nto      gcc/config/arm/t-nto
    export MAKEINFO=true
  '';

  # Read the proprietary sysroot in place (Model A). Honored under
  # `--option sandbox relaxed`; no proprietary bytes enter the store.
  __noChroot = true;

  # GCC 9 host build with a modern host gcc emits many warnings; never -Werror.
  enableParallelBuilding = true;
  hardeningDisable = [ "format" ];

  configurePhase = ''
    runHook preConfigure
    mkdir -p ../build && cd ../build
    ../$sourceRoot/configure \
      --build=${stdenv.buildPlatform.config} \
      --host=${stdenv.hostPlatform.config} \
      --target=${target} \
      --prefix=$out \
      --with-sysroot=${sysroot} \
      --with-build-sysroot=${sysroot} \
      --with-gnu-as --with-gnu-ld \
      --with-as=${binutils}/bin/${target}-as \
      --with-ld=${binutils}/bin/${target}-ld \
      --disable-multilib \
      --disable-nls --disable-werror \
      --disable-libssp --disable-tls --disable-libstdcxx-pch \
      --enable-__cxa_atexit --enable-gnu-indirect-function \
      --with-arch=armv7-a --with-float=softfp --with-fpu=vfpv3-d16 --with-mode=thumb \
      --enable-languages=${if langCxx then "c,c++" else "c"} \
      --enable-shared \
      MAKEINFO=true
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make $makeFlags
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install
    runHook postInstall
  '';

  meta = {
    description = "GCC ${version} cross-compiler for BlackBerry 10 / QNX 8 ARM (${target})";
    platforms = [ "x86_64-linux" ];
  };
}
