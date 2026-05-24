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
  # Debug aid: build only the compiler + libgcc (skip libstdc++) to get a fast,
  # testable g++ for iterating on header/spec issues.
  buildLibsOnly ? false,
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

    # libstdc++ QNX config, replicating the BlackBerry/QNX GCC 4.9 donor that
    # successfully built libstdc++ against these exact headers:
    #   configure.host: c_model=c + c_compatibility=yes (the c-compatibility
    #     header model -- include/c/<cmath> #undefs the C math macros and defines
    #     clean std:: overloads). The donor glob nto-qnx[68]* already matches
    #     nto-qnx8; add a case mirroring it (no autoreconf -- plain shell).
    sed -i '/^  qnx6\.\[12\]\*)/i\  nto-qnx* | qnx[78]*)\n    os_include_dir="os/qnx/qnx6.1"\n    c_model=c\n    c_compatibility=yes\n    ;;' \
      libstdc++-v3/configure.host
    #   os_defines.h: the donor's QNX defines (pthreads in libc; enable QNX ext).
    sed -i '/#define _GLIBCXX_OS_DEFINES 1/a #define _GLIBCXX_GTHREAD_USE_WEAK 0\n#define _QNX_SOURCE 1' \
      libstdc++-v3/config/os/qnx/qnx6.1/os_defines.h
    #   crossconfig.m4 / generated configure: the cross AC_DEFINE(HAVE_*) stanza,
    #   keyed on $host (donor matches *-qnx8*).
    sed -i 's/\*-qnx6\.1\* | \*-qnx6\.2\*)/*-qnx6.1* | *-qnx6.2* | *-nto-qnx* | *-qnx[78]*)/' \
      libstdc++-v3/configure libstdc++-v3/crossconfig.m4

    # QNX <ctype.h> defines short mask macros (_UP, _LO, ...) that persist after
    # ctype_base.h captures them, colliding with libstdc++ identifiers (e.g. _UP
    # in <bits/unique_ptr.h>). Undefine them after ctype_base.h.
    printf '\n#undef _UP\n#undef _LO\n#undef _DI\n#undef _SP\n#undef _PU\n#undef _CN\n#undef _XD\n#undef _BB\n#undef _XS\n#undef _XA\n#undef _XB\n' \
      >> libstdc++-v3/config/os/qnx/qnx6.1/ctype_base.h

    # QNX's <sys/platform.h>/<sys/compiler_gnu.h> predefine GCC's own stddef.h
    # guard markers (_GCC_PTRDIFF_T/_GCC_SIZE_T/_GCC_WCHAR_T, "to override the
    # gcc local include files") plus the __*_T type signals, expecting QNX's
    # own <stddef.h> to provide size_t/ptrdiff_t/wchar_t. GCC's stddef.h shadows
    # QNX's, so it honours the markers, skips its typedefs, and the types are
    # never declared -- breaking the libstdc++ build (cxxabi.h, time.h).
    #
    # Mirror the QNX-patched GCC: when a QNX header has run first (detected via
    # _GCC_SIZE_T), defer to QNX's <stddef.h> via #include_next -- it consumes
    # its own __*_T signals coherently. Otherwise (e.g. libgcc, which includes
    # <stddef.h> with no QNX header in scope) use GCC's own definitions.
    # When a QNX header has run first (detected via _GCC_SIZE_T from
    # <sys/compiler_gnu.h>), delegate to QNX's own <stddef.h> -- it consumes its
    # __PTRDIFF_T/__SIZE_T signals coherently and defines size_t/ptrdiff_t/
    # wchar_t. (GCC's body can't: QNX's _GCC_PTRDIFF_T etc. make it skip them.)
    # Otherwise (e.g. libgcc, no QNX header in scope) use GCC's own definitions.
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
    make $makeFlags ${if buildLibsOnly then "all-gcc all-target-libgcc" else ""}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make ${if buildLibsOnly then "install-gcc install-target-libgcc" else "install"}
    runHook postInstall
  '';

  meta = {
    description = "GCC ${version} cross-compiler for BlackBerry 10 / QNX 8 ARM (${target})";
    platforms = [ "x86_64-linux" ];
  };
}
