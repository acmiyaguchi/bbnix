/* Definitions for ARM EABI QNX Neutrino targets.
   Copyright (C) Free Software Foundation, Inc.

This file is part of GCC.

GCC is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3, or (at your option)
any later version.

GCC is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GCC; see the file COPYING3.  If not see
<http://www.gnu.org/licenses/>.  */

/* SPDX-License-Identifier: GPL-3.0-or-later

   Modified by bbnix in 2026: forward-ported to GCC 9 from the BlackBerry/QNX
   GCC 4.9 fork (github.com/berryfarm/gcc, branch gcc-4.9).

   Adapted for a Nix cross build with --with-sysroot=<qnx6>:
     - All library/CRT search paths now use the GCC spec escape %R (the
       sysroot) plus the fixed armle-v7 osdir, instead of the donor's
       env-var form %$QNX_TARGET/arm{le}-v7...  We only target softfp
       armle-v7, so the directory is always armle-v7 (no hf/be variants).
     - SUBTARGET_CPP_SPEC no longer pulls in QNX_SYSTEM_INCLUDES; C headers
       come from the default sysroot search and C++ headers from
       --with-gxx-include-dir.
   System headers stay at <sysroot>/usr/include; libs/CRT at
   <sysroot>/armle-v7/lib.  */

#define HAVE_ATEXIT

/* We default to the "aapcs-linux" ABI so that enums are int-sized by
   default.  */
#undef  ARM_DEFAULT_ABI
#define ARM_DEFAULT_ABI ARM_ABI_AAPCS_LINUX

#undef SIZE_TYPE
#define SIZE_TYPE "unsigned int"

#undef PTRDIFF_TYPE
#define PTRDIFF_TYPE "int"

#undef DEFAULT_SIGNED_CHAR
#define DEFAULT_SIGNED_CHAR  1

#define	OBJECT_FORMAT_ELF

#undef TARGET_OS_CPP_BUILTINS
#define TARGET_OS_CPP_BUILTINS()                \
do {                                            \
	TARGET_BPABI_CPP_BUILTINS();		\
	NTO_TARGET_OS_CPP_BUILTINS();		\
	builtin_define ("__ARM__");             \
} while (0)

#undef ASM_SPEC
#define ASM_SPEC \
"%{EB:-EB} %{!EB:-EL} %{EL:-EL} \
 %{fpic|fPIC:--defsym __PIC__=1} \
 %{mcpu=*:-mcpu=%*} \
 %{march=*:-march=%*} \
 %{mfloat-abi=*} %{mfpu=*} \
 %{mapcs-float:-mfloat} \
 -meabi=5"

/* Link-time library search and rpath-link, anchored at the sysroot.  These
   are not recorded in the output binary (no RUNPATH leakage).  */
/* The donor's %v1.%v2.%v3 compiler-version spec was removed in GCC 9.  We build
   our own libgcc (found via the compiler exec prefix, not here), but we reuse
   the *device's* libstdc++ 4.8.3, whose linker-name symlink lives in the
   sysroot's lib/gcc/4.8.3 dir (libstdc++.so -> ../../libstdc++.so.6).  Add that
   dir so the g++ driver's implicit `-lstdc++' resolves to the device's
   libstdc++.so.6, matching the headers in usr/include/c++/4.8.3.  */
#define QNX_SYSTEM_LIBDIRS \
"-L%R/armle-v7/lib/gcc/4.8.3 \
 -L%R/armle-v7/lib \
 -L%R/armle-v7/usr/lib \
 -L%R/armle-v7/opt/lib \
 -rpath-link %R/armle-v7/lib/gcc/4.8.3:%R/armle-v7/lib:%R/armle-v7/usr/lib:%R/armle-v7/opt/lib "

#undef LIB_SPEC
#define LIB_SPEC \
  QNX_SYSTEM_LIBDIRS \
  "%{!symbolic: -lc -Bstatic %{static|nopie: -lc;:-lcS}}"

#undef LIBGCC_SPEC
#define LIBGCC_SPEC "-lgcc"

/* crt1/crti/crtn come from the sysroot (named explicitly via %R); crtbegin/
   crtend are GCC's own and are found via %s in the compiler exec prefix.
   Default is PIE: crt1S.o + the PIC crtbeginS.o/crtendS.o; static/nopie selects
   the non-PIC variants.  */
/* crt1/crti/crtn come from the sysroot (named explicitly via %R); crtbegin/
   crtend are GCC's own, found via %s.  Executables use the standard crt1.o +
   non-PIC crtbegin/crtend (ET_EXEC); shared objects use the PIC crtbeginS/
   crtendS.  NOTE: PIE executables are not produced yet -- the binutils 2.41
   `armnto' ld emulation lacks a PIE script (`-pie' falls back to ET_EXEC),
   so we emit standard dynamically-linked executables.  PIE is a follow-up.  */
#undef STARTFILE_SPEC
#define STARTFILE_SPEC \
"%{!shared:%R/armle-v7/lib/crt1.o} \
 %R/armle-v7/lib/crti.o %{shared:crtbeginS.o%s;:crtbegin.o%s} "

#undef ENDFILE_SPEC
#define ENDFILE_SPEC \
"%{shared:crtendS.o%s;:crtend.o%s} %R/armle-v7/lib/crtn.o"

#undef LINK_SPEC
#define LINK_SPEC \
"%{h*} %{v:-V} \
 %{b} %{Wl,*:%*} \
 %{!r:--build-id=md5} \
 %{static:-Bstatic} \
 %{shared} \
 %{symbolic:-Bsymbolic} \
 %{G:-G} %{MAP:-Map mapfile} \
 %{!shared: \
   %{!static: \
     %{rdynamic:-export-dynamic}} \
   --dynamic-linker /usr/lib/ldqnx.so.2} \
 -m armnto -X \
 %{EB:-EB} %{!EB:-EL} %{EL:-EL}"

#undef CPP_APCS_PC_DEFAULT_SPEC
#define CPP_APCS_PC_DEFAULT_SPEC "-D__APCS_32__"

#undef	SUBTARGET_CPP_SPEC
#define	SUBTARGET_CPP_SPEC "\
 %{!EB:-D__LITTLEENDIAN__ -D__ARMEL__} \
 %{EB:-D__BIGENDIAN__ -D__ARMEB__} \
 %{posix:-D_POSIX_SOURCE}"

#undef	CC1_SPEC
#define	CC1_SPEC " \
%{EB:-mbig-endian} %{!EB:-mlittle-endian}"

/* Call the function profiler with a given profile label.
   This is _mcount on other nto's.  It is mcount on ntoarm.  */
#undef ARM_FUNCTION_PROFILER
#define ARM_FUNCTION_PROFILER(STREAM, LABELNO)  				\
{									\
  fprintf (STREAM, "\tpush {lr}\n");  	    			\
  fprintf (STREAM, "\tbl\tmcount%s\n", NEED_PLT_RELOC ? "(PLT)" : "");	\
}

#undef SUBTARGET_EXTRA_SPECS
#define SUBTARGET_EXTRA_SPECS                           \
  { "subtarget_asm_float_spec", SUBTARGET_ASM_FLOAT_SPEC },

#undef SUBTARGET_ASM_FLOAT_SPEC
#define SUBTARGET_ASM_FLOAT_SPEC "\
 %{mapcs-float:-mfloat} %{!mhard-float:-mfpu=softvfp} %{mhard-float:-mfpu=vfp}"

#undef CLEAR_INSN_CACHE
#define CLEAR_INSN_CACHE(BEG, END)                                      \
{                                                                       \
 register unsigned long _beg __asm ("a1") = (unsigned long) (BEG);      \
  register unsigned long _len __asm ("a2") = (unsigned long) (END) - (unsigned long) (BEG); \
  register unsigned long _flg __asm ("a3") = 0x1000000;			\
  __asm __volatile ("bl	msync"						\
                    : "=r" (_beg)					\
                    : "r" (_beg), "r" (_len), "r" (_flg));		\
}

#undef  DEFAULT_STRUCTURE_SIZE_BOUNDARY
#define DEFAULT_STRUCTURE_SIZE_BOUNDARY 8

#define USE_OLD_ATBASE
