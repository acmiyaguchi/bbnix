# SPDX-License-Identifier: MIT
# tmux 3.5a cross-built from source for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM). Pure C -- no libstdc++ ABI concerns (cf. mosh).
#
# Dependencies, all from bbnix: libevent (event loop; static .a embedded),
# ncursesw (terminal), and libbbnixcompat (ncursesw's NEEDED, plus -lsocket for
# the client/server unix socket). The interesting QNX gap is the pty: tmux needs
# forkpty(3), which QNX ships only in the *static* libc (libcS.a's pty.o +
# posix_pty.o), not in libc.so.3 -- and tmux's configure does not recognise the
# nto-qnx host to pick a compat shim. We extract those two PIC objects from the
# sysroot's libcS.a and link them straight into the executable, and supply a
# <pty.h> shim so configure finds the declaration. See pkgs/files/pty.h.
{
  stdenv,
  lib,
  fetchurl,
  pkg-config,
  patchelf,
  bison,
  binutils,
  gcc,
  libevent,
  ncurses,
  compat,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-tmux";
  version = "3.5a";

  src = fetchurl {
    url = "https://github.com/tmux/tmux/releases/download/${version}/tmux-${version}.tar.gz";
    sha256 = "0lc9341h3k22jmy8qm42n090nq8kj2x8aw0mck6dyw3ihz86n88n";
  };

  # bison: tmux regenerates its cmd-parse.y grammar at build time (AC_PROG_YACC).
  nativeBuildInputs = [ pkg-config patchelf bison ];

  # QNX interactive-attach fix. Passing a pty (resource-manager) fd over the
  # client/server AF_UNIX socket via SCM_RIGHTS corrupts the QNX recvmsg --
  # both the fd AND the inline data bytes of that read are lost -- which drops
  # the IDENTIFY_STDIN..IDENTIFY_DONE batch of the attach handshake. Without
  # IDENTIFY_DONE the server never sets CLIENT_IDENTIFIED, never drains the
  # client's command queue, and the queued attach-session never runs (blank
  # hang, server at 0% CPU). The patch stops the QNX client from passing the
  # tty fd and has the server reopen the terminal by the name the client
  # already sends -- exactly tmux's own __CYGWIN__ workaround, extended to QNX.
  # Detached paths (new-session -d/send-keys/capture-pane) pass a pipe fd,
  # which is unaffected, which is why only interactive attach was broken.
  patches = [ ./patches/tmux-3.5a-qnx-attach.patch ];

  # QNX's <limits.h> #undefs IOV_MAX under __EXT_XOPEN_EX (it's the runtime
  # sysconf(_SC_IOV_MAX) value there, not a compile-time constant), so a -D
  # can't survive. tmux's bundled imsg sizes a stack `iovec[IOV_MAX]`; add the
  # guard upstream imsg now carries, right after <limits.h> (whose include guard
  # stops a later re-undef). QNX's writev ceiling is UIO_MAXIOV (1024).
  postPatch = ''
    substituteInPlace compat/imsg-buffer.c \
      --replace '#include <limits.h>' \
        '#include <limits.h>
#ifndef IOV_MAX
#define IOV_MAX 1024
#endif'
  '';

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}

    # forkpty/openpty live only in the static libc on QNX (libcS.a, PIC). Pull
    # the two objects that define the pty stack -- pty.o (forkpty/openpty/
    # login_tty) and posix_pty.o (posix_openpt/grantpt/unlockpt/ptsname) -- and
    # link them as plain objects below. Their only undefined refs (ioctl, open,
    # devctl, ...) are all in libc.so.3. See header.
    mkdir -p qnxpty
    ( cd qnxpty && ${binutils}/bin/${target}-ar x ${sysroot}/armle-v7/lib/libcS.a pty.o posix_pty.o )

    # Shims: <pty.h> (forkpty/openpty decl via <unix.h>), <syslog.h> (QNX ships
    # slog2, not syslog, but libc exports the BSD symbols), and <langinfo.h>
    # (nl_langinfo(CODESET) -- libbbnixcompat supplies the symbol). See pkgs/files.
    mkdir -p shim
    cp ${./files/pty.h} shim/pty.h
    cp ${./files/syslog.h} shim/syslog.h
    cp ${./files/langinfo.h} shim/langinfo.h

    # stddefFlag: the QNX size_t/unistd.h cross gap (qnx-common.nix). Bypass the
    # libevent PKG_CHECK_MODULES (our .pc isn't on a sysroot pkg-config path) by
    # feeding its flags directly; ncursesw is resolved via PKG_CONFIG_PATH below.
    export LIBEVENT_CFLAGS="-I${libevent}/include"
    export LIBEVENT_LIBS="-L${libevent}/lib -levent"
    export PKG_CONFIG_PATH="${ncurses}/lib/pkgconfig"

    # stddefFlag / saRestartFlag: the QNX size_t and missing-SA_RESTART gaps
    # (qnx-common.nix). ncursesw's -I/-L come from PKG_CONFIG_PATH above (its .pc
    # carries the include/ncursesw subdir too); only libevent (fed directly) and
    # the shim dir need explicit paths here. (The other QNX gap, IOV_MAX, can't
    # be a -D -- patched in postPatch instead.)
    export CPPFLAGS="${qnx.stddefFlag} ${qnx.saRestartFlag} -I$PWD/shim -I${libevent}/include"
    # -L${compat}/lib so ld can resolve ncursesw.so's NEEDED libbbnixcompat.so.1.
    export LDFLAGS="-L${libevent}/lib -L${compat}/lib"
    # pty objects as explicit inputs (always pulled, refs resolve against
    # libc.so.3); -lsocket for the client/server socket; -lbbnixcompat for
    # ncursesw's wcwidth/tsearch (and tmux's own wcwidth). LIBS is appended after
    # the tmux objects, so forkpty/wcwidth references resolve.
    export LIBS="$PWD/qnxpty/pty.o $PWD/qnxpty/posix_pty.o -lsocket -lbbnixcompat"

    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --sysconfdir=/accounts/1000/shared/misc/etc
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install
    runHook postInstall
  '';

  # Ship NO RPATH: the device's QNX loader does not expand $ORIGIN, so deploy
  # sets LD_LIBRARY_PATH=<libdir>. See [[bbnix-openssh-userland]].
  postFixup = ''
    patchelf --remove-rpath $out/bin/tmux
  '';

  meta = {
    description = "tmux ${version} cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.isc;
    platforms = [ "x86_64-linux" ];
  };
})
