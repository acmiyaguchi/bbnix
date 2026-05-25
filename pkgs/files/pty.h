/* SPDX-License-Identifier: MIT
 * Minimal <pty.h> shim for BlackBerry 10 / QNX 8.
 *
 * QNX declares forkpty(3)/openpty(3)/login_tty(3) in <unix.h>, not the
 * Linux/BSD <pty.h>/<util.h> that portable code (tmux) probes for. The symbols
 * themselves are static-only -- present in libcS.a's pty.o, absent from
 * libc.so.3 -- so consumers must also link those objects (see pkgs/tmux.nix).
 *
 * This header just gives <pty.h>-probing configure scripts a header to find and
 * a forkpty/openpty prototype; the real declarations come from <unix.h>, which
 * forward-declares the struct winsize/termios pointers it needs.
 */
#ifndef _BBNIX_PTY_H
#define _BBNIX_PTY_H

#include <unix.h>

#endif /* _BBNIX_PTY_H */
