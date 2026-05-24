# SPDX-License-Identifier: MIT
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
#         langCxx=true builds the C++ compiler (cc1plus) + libgcc but NOT a C++
#         standard library: the BB10/QNX sysroot already ships a complete,
#         working libstdc++ 4.8.3 (headers under usr/include/c++/4.8.3 + the
#         armle-v7 libstdc++.so.6.0.19) that was built to coexist with QNX's
#         Dinkumware C headers. We point g++ at those headers via gxxIncludeDir
#         and link the device's libstdc++ -> milestone M3. This sidesteps the
#         intractable task of rebuilding GCC 9's own libstdc++ against QNX's
#         _STD_USING namespace machinery, and yields an ABI that matches the
#         device exactly.
{
  stdenv,
  lib,
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
  # Path to the sysroot's prebuilt C++ headers (e.g. <qnx6>/usr/include/c++/4.8.3).
  # When set (with langCxx), g++ uses these headers + the sysroot's libstdc++
  # and GCC's own libstdc++ is NOT built.
  gxxIncludeDir ? null,
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

    # NOTE: we do NOT build GCC 9's own libstdc++ -- the QNX sysroot supplies a
    # complete, working libstdc++ 4.8.3. So the donor's libstdc++ QNX porting
    # (configure.host c_model, crossconfig, ctype/namespace reconciliation) is
    # intentionally absent here; see the file header. The stddef delegation
    # below still matters: it governs how GCC's <stddef.h> behaves when *user*
    # C++ code (and libgcc) pulls in QNX headers.

    # QNX's <sys/platform.h>/<sys/compiler_gnu.h> predefine GCC's own stddef.h
    # guard markers (_GCC_PTRDIFF_T/_GCC_SIZE_T/_GCC_WCHAR_T, "to override the
    # gcc local include files") plus the __*_T type signals, expecting QNX's
    # own <stddef.h> to provide size_t/ptrdiff_t/wchar_t. GCC's stddef.h shadows
    # QNX's, so it honours the markers, skips its typedefs, and the types end up
    # never declared -- breaking C++ compiles that pull in QNX headers (e.g. the
    # device's <cstddef>, cxxabi, <ctime>).
    #
    # Fix (mirroring the QNX-patched GCC): when a QNX header has run first
    # (detected via _GCC_SIZE_T from <sys/compiler_gnu.h>), delegate to QNX's
    # own <stddef.h> via #include_next -- it consumes its __PTRDIFF_T/__SIZE_T
    # signals coherently and defines size_t/ptrdiff_t/wchar_t. Otherwise (e.g.
    # libgcc, no QNX header in scope) use GCC's own definitions.
    # Two gaps QNX's 2014 stddef leaves vs GCC 9 / C++11 are filled here:
    #   - max_align_t (libstdc++ <cstddef> does `using ::max_align_t`);
    #   - offsetof, which GCC's stddef only defines on a full include (no
    #     __need_offsetof handling) and QNX's only on first include -- so
    #     guarantee it (it is always __builtin_offsetof on GCC).
    { printf '#if defined(__QNXNTO__) && defined(_GCC_SIZE_T)\n#include_next <stddef.h>\n#if defined(__cplusplus) && !defined(_GCC_MAX_ALIGN_T)\n#define _GCC_MAX_ALIGN_T\ntypedef struct { long long __bbnix_ll __attribute__((__aligned__(__alignof__(long long)))); long double __bbnix_ld __attribute__((__aligned__(__alignof__(long double)))); } max_align_t;\n#endif\n#else\n'; \
      cat gcc/ginclude/stddef.h; \
      printf '\n#endif /* QNX stddef delegation */\n#if defined(__QNXNTO__) && !defined(offsetof)\n#define offsetof(TYPE, MEMBER) __builtin_offsetof (TYPE, MEMBER)\n#endif\n'; } > gcc/ginclude/stddef.h.qnx
    mv gcc/ginclude/stddef.h.qnx gcc/ginclude/stddef.h


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
      --disable-libssp --disable-tls \
      --enable-__cxa_atexit --enable-gnu-indirect-function \
      --with-arch=armv7-a --with-float=softfp --with-fpu=vfpv3-d16 --with-mode=thumb \
      --enable-languages=${if langCxx then "c,c++" else "c"} \
      --enable-shared \
      ${lib.optionalString (gxxIncludeDir != null) "--with-gxx-include-dir=${gxxIncludeDir}"} \
      MAKEINFO=true
    runHook postConfigure
  '';

  # Build the compiler + libgcc only. With langCxx this still produces cc1plus/
  # g++ for C++ sources; we never build GCC's own libstdc++ (the C++ runtime is
  # the QNX sysroot's libstdc++ 4.8.3 -- see the file header).
  buildPhase = ''
    runHook preBuild
    make $makeFlags all-gcc all-target-libgcc
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install-gcc install-target-libgcc
    runHook postInstall
  '';

  meta = {
    description = "GCC ${version} cross-compiler for BlackBerry 10 / QNX 8 ARM (${target})";
    # License of the built artifact (GCC; GPLv3+ with the Runtime Library
    # Exception on libgcc), not of this recipe (MIT).
    license = lib.licenses.gpl3Plus;
    platforms = [ "x86_64-linux" ];
  };
}
