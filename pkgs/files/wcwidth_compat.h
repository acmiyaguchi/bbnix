/* SPDX-License-Identifier: MIT
 * Declarations for the wcwidth(3) functions QNX's <wchar.h> omits.
 *
 * QNX provides neither the symbol nor a declaration for wcwidth/wcswidth
 * (libbbnixcompat supplies the symbol; see pkgs/files/qnx-compat.c). C code
 * gets away with an implicit declaration and just warns, but C++ treats the
 * missing declaration as a hard error -- mosh's terminal.cc calls wcwidth
 * directly. Force-include this so the prototype is in scope; it matches the
 * libbbnixcompat definitions.
 */
#ifndef BBNIX_WCWIDTH_COMPAT_H
#define BBNIX_WCWIDTH_COMPAT_H

#include <wchar.h>

#ifdef __cplusplus
extern "C" {
#endif

int wcwidth(wchar_t wc);
int wcswidth(const wchar_t *pwcs, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* BBNIX_WCWIDTH_COMPAT_H */
