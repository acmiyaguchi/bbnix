# SPDX-License-Identifier: MIT
# BusyBox 1.36.1 cross-built for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM).
#
# BusyBox is Linux-first, so this is intentionally a conservative applet subset:
# basic coreutils, grep/sed/find/xargs, tar/gzip/bzip2/xz, and terminal clear /
# reset / resize. Applets that assume Linux-only APIs (/proc, mount, utimensat,
# richer termios, etc.) stay disabled until they are ported and device-tested.
{
  stdenv,
  lib,
  fetchurl,
  perl,
  binutils,
  gcc,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  # Recorded for symmetry with the other recipes; the cross gcc already knows
  # the sysroot, so BusyBox needs no explicit reference to it.
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-busybox";
  version = "1.36.1";

  src = fetchurl {
    url = "https://busybox.net/downloads/busybox-${version}.tar.bz2";
    sha256 = "0573gpj51phcz04sg77iznvcxmf5jnbk9gn3g5r9x02daz4j9k5q";
  };

  # BusyBox generates usage docs with pod2man/pod2text during a normal build.
  nativeBuildInputs = [ perl ];

  postPatch = ''
    # QNX has neither glibc's endian headers nor byteswap.h; armle-v7 is little
    # endian and GCC gives us the byte-swap builtins.
    substituteInPlace include/platform.h \
      --replace '#else
# include <byteswap.h>
# include <endian.h>
#endif' \
        '#elif defined(__QNXNTO__)
# include <sys/param.h>
# define bswap_64 __builtin_bswap64
# define bswap_32 __builtin_bswap32
# define bswap_16 __builtin_bswap16
#else
# include <byteswap.h>
# include <endian.h>
#endif'

    # Platform feature probes are static assumptions in BusyBox. Mark the QNX
    # gaps/mismatches so BusyBox builds and uses its portable fallbacks.
    substituteInPlace include/platform.h \
      --replace '#if defined(__UCLIBC__)' \
        '#if defined(__QNXNTO__)
# undef HAVE_DPRINTF
# undef HAVE_GETLINE
# undef HAVE_MEMPCPY
# undef HAVE_MNTENT_H
# undef HAVE_NET_ETHERNET_H
# undef HAVE_PRINTF_PERCENTM
# undef HAVE_STPCPY
# undef HAVE_STPNCPY
# undef HAVE_STRCHRNUL
# undef HAVE_STRVERSCMP
# undef HAVE_SYS_STATFS_H
# undef HAVE_UNLOCKED_STDIO
# undef HAVE_UNLOCKED_LINE_OPS
# undef HAVE_VASPRINTF
#endif

#if defined(__UCLIBC__)'
    substituteInPlace include/platform.h \
      --replace '#ifndef HAVE_VASPRINTF
extern int vasprintf' \
        '#ifndef HAVE_VASPRINTF
# include <stdarg.h>
extern int vasprintf'

    # QNX's stdlib declares incompatible itoa/utoa helpers. Keep BusyBox's
    # one-argument helpers internal by renaming them through macros after system
    # headers have been included.
    substituteInPlace include/libbb.h \
      --replace '#include "platform.h"' '#include <stddef.h>
#include "platform.h"' \
      --replace '#if 1 /*def __GLIBC__*/
#define GETOPT_RESET() (optind = 0)
#else /* BSD style */' '#if defined(__QNXNTO__)
#define GETOPT_RESET() (optind = 1)
#elif 1 /*def __GLIBC__*/
#define GETOPT_RESET() (optind = 0)
#else /* BSD style */' \
      --replace '#if ENABLE_SELINUX' '#if defined(__QNXNTO__)
# define itoa bb_itoa
# define utoa bb_utoa
#endif

#if ENABLE_SELINUX' \
      --replace '#ifdef __GLIBC__
/* At least glibc has horrendously large inline for this, so wrap it */
unsigned long long bb_makedev(unsigned major, unsigned minor) FAST_FUNC;
#undef makedev
#define makedev(a,b) bb_makedev(a,b)
#endif' \
        '#ifdef __GLIBC__
/* At least glibc has horrendously large inline for this, so wrap it */
unsigned long long bb_makedev(unsigned major, unsigned minor) FAST_FUNC;
#undef makedev
#define makedev(a,b) bb_makedev(a,b)
#endif
#ifdef __QNXNTO__
/* QNX makedev has a node argument; BusyBox calls the Linux/BSD two-arg form. */
#undef makedev
#define makedev(a,b) ((dev_t)((((dev_t)0) << 16) | (((dev_t)(a)) << 10) | (dev_t)(b)))
#endif'

    # libbb's x86 assembly objects are guarded internally, but CONFIG_EXTRA_CFLAGS
    # is also applied to assembler inputs. Dropping them avoids forcing C headers
    # through the ARM assembler.
    substituteInPlace libbb/Kbuild.src \
      --replace "lib-y += makedev.o" "" \
      --replace "lib-y += hash_md5_sha_x86-64.o" "" \
      --replace "lib-y += hash_md5_sha_x86-64_shaNI.o" "" \
      --replace "lib-y += hash_md5_sha_x86-32_shaNI.o" "" \
      --replace "lib-y += hash_md5_sha256_x86-64_shaNI.o" "" \
      --replace "lib-y += hash_md5_sha256_x86-32_shaNI.o" ""

    # QNX libc lacks strndup; implement xstrndup directly instead of expecting a
    # libc symbol.
    substituteInPlace libbb/xfuncs_printf.c \
      --replace 't = strndup(s, n);

	if (t == NULL)
		bb_die_memory_exhausted();

	return t;' \
        'size_t len = strnlen(s, n);
	t = xmalloc(len + 1);
	memcpy(t, s, len);
	t[len] = 0;
	return t;'
  '';

  configurePhase = ''
    runHook preConfigure

    # BusyBox wants a single CROSS_COMPILE prefix for gcc and binutils, while
    # bbnix keeps them in separate derivations. Synthesize the expected prefix.
    mkdir -p cross-bin
    for tool in gcc cpp; do
      ln -s ${gcc}/bin/${target}-$tool cross-bin/${target}-$tool
    done
    for tool in ar as ld nm objcopy objdump ranlib readelf strip; do
      ln -s ${binutils}/bin/${target}-$tool cross-bin/${target}-$tool
    done

    # Inject the QNX gap flags from the single source of truth in qnx-common
    # rather than hardcoding them in the checked-in .config (-include stddef.h
    # for [[qnx-unistd-size-t-stddef-gap]]; -DSA_RESTART=0 for QNX's omitted
    # signal flag). The .config carries an @QNX_CFLAGS@ placeholder.
    cp ${./files/busybox.config} .config
    substituteInPlace .config \
      --replace '@QNX_CFLAGS@' '${qnx.stddefFlag} ${qnx.saRestartFlag}'
    make oldconfig < /dev/null >/dev/null
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES CROSS_COMPILE=$PWD/cross-bin/${target}-
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make CROSS_COMPILE=$PWD/cross-bin/${target}- CONFIG_PREFIX=$out install
    runHook postInstall
  '';

  meta = {
    description = "BusyBox ${version} conservative applet subset cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
})
