/* Base configuration for all QNX Neutrino targets.
   Copyright (C) 2006 Free Software Foundation, Inc.

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

   Adapted for a Nix cross build:
     - Removed GCC_DRIVER_HOST_INITIALIZATION (it required $QNX_HOST/$QNX_TARGET
       env vars and fatal_error'd otherwise); we use --with-sysroot instead.
     - Removed QNX_SYSTEM_INCLUDES (env-var driven -isystem/-isysroot); the
       default sysroot search (<sysroot>/usr/include) plus --with-gxx-include-dir
       supply the C and C++ headers.
     - Removed MFLIB_SPEC (libmudflap was deleted in GCC 4.9/5+).  */

#undef TARGET_NEUTRINO
#define TARGET_NEUTRINO 1

/* NO_IMPLICIT_EXTERN_C (defined by the GCC 4.9 donor) is obsolete and poisoned
   in GCC 9 -- implicit extern "C" header wrapping was removed -- so it is
   omitted here.  */

/* Allow stabs and dwarf, and make dwarf the default for Neutrino.  */
#undef PREFERRED_DEBUGGING_TYPE
#undef DBX_DEBUGGING_INFO
#undef DWARF_DEBUGGING_INFO
#undef DWARF2_DEBUGGING_INFO

#define PREFERRED_DEBUGGING_TYPE DWARF2_DEBUG
#define DBX_DEBUGGING_INFO
#define DWARF_DEBUGGING_INFO
#define DWARF2_DEBUGGING_INFO

#define SUPPORTS_WEAK 1

#undef MD_EXEC_PREFIX
#undef MD_STARTFILE_PREFIX

#ifdef HAVE_GNU_INDIRECT_FUNCTION
#define GNU_INDIRECT_FUNCTION if (HAVE_GNU_INDIRECT_FUNCTION) \
				 builtin_define ("__GNU_INDIRECT_FUNCTION__");
#else
#define GNU_INDIRECT_FUNCTION
#endif

#define NTO_TARGET_OS_CPP_BUILTINS()		\
do {                                            \
        builtin_define ("__QNX__");             \
        builtin_define ("__QNXNTO__");          \
        builtin_define ("__ELF__");             \
        builtin_assert ("system=posix");        \
        builtin_assert ("system=qnx");          \
        builtin_assert ("system=nto");          \
        builtin_assert ("system=qnxnto");       \
        builtin_define ("__PRAGMA_PACK_PUSH_POP__");	\
	GNU_INDIRECT_FUNCTION			\
    } while (0)

/* Don't set libgcc.a's gthread/pthread symbols to weak, as our
   libc has them as well, and we get problems when linking static,
   as libgcc.a will get a symbol value of 0.  */
#define GTHREAD_USE_WEAK 0

#undef THREAD_MODEL_SPEC
#define THREAD_MODEL_SPEC "posix"

/* Under Neutrino, there is one set of header files for all targets.  wchar_t is
   defined as a 32 bit unsigned integer.  */
#undef WCHAR_TYPE
#define WCHAR_TYPE "unsigned int"

#undef WCHAR_TYPE_SIZE
#define WCHAR_TYPE_SIZE 32

#undef WINT_TYPE
#define WINT_TYPE "long int"

#undef WINT_TYPE_SIZE
#define WINT_TYPE_SIZE 32

#define TARGET_POSIX_IO

#undef GOMP_SELF_SPECS
#define GOMP_SELF_SPECS ""

#undef LINK_GCC_C_SEQUENCE_SPEC
#define LINK_GCC_C_SEQUENCE_SPEC \
  "%{static:--start-group} %G %L %{static:--end-group}%{!static:%G}"

#if defined(HAVE_LD_EH_FRAME_HDR)
#define LINK_EH_SPEC "%{!static:--eh-frame-hdr} "
#endif
