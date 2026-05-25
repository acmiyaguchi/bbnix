/* SPDX-License-Identifier: MIT
 * Minimal <langinfo.h> shim for QNX 8 / BB10.
 *
 * QNX ships no <langinfo.h> and no nl_langinfo(3) (it has setlocale, but not
 * the langinfo query API). mosh's locale_utils.cc needs exactly one item,
 * nl_langinfo(CODESET), to decide whether the locale is UTF-8. This header
 * declares just that surface; libbbnixcompat supplies the implementation,
 * which derives the codeset from the locale environment. See
 * pkgs/files/qnx-compat.c and pkgs/qnx-compat.nix.
 *
 * The CODESET value is private to this shim + its implementation; only their
 * agreement matters, not the glibc numbering.
 */
#ifndef BBNIX_LANGINFO_H
#define BBNIX_LANGINFO_H

#ifdef __cplusplus
extern "C" {
#endif

typedef int nl_item;

#define CODESET 1

char *nl_langinfo(nl_item item);

#ifdef __cplusplus
}
#endif

#endif /* BBNIX_LANGINFO_H */
