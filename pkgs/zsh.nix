# SPDX-License-Identifier: MIT
# zsh 5.9 cross-built from source for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM). A richer interactive shell than the device's
# minimal ksh / Term49's bundled mksh: completion, history, zle line editing.
#
# Built as ONE static binary (--disable-dynamic): all modules are linked in, so
# there is no loadable-module .so tree to deploy and zsh's whole dlopen/dynamic
# probe surface (the Linux-isms) is sidestepped -- matching how we embed libevent
# (tmux) and libprotobuf (mosh). Dependencies, all already in bbnix: ncursesw
# (terminal; its NEEDED is libbbnixcompat) and libbbnixcompat (wcwidth +
# nl_langinfo(CODESET), the QNX libc gaps zsh hits). Multibyte/UTF-8 rides QNX's
# own GNU libiconv (libiconv.so.1, on-device) via -liconv -- no new deploy dep.
#
# autoconf cross-build: --host marks it cross so configure skips most run-tests,
# but a handful of probes that *run* a target binary need their results
# pre-seeded as zsh_cv_* cache vars (we cannot run QNX ARM binaries on the host).
{
  stdenv,
  lib,
  fetchurl,
  patchelf,
  binutils,
  gcc,
  ncurses,
  compat,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-zsh";
  version = "5.9";

  src = fetchurl {
    url = "https://www.zsh.org/pub/zsh-${version}.tar.xz";
    sha256 = "1mdc8lnq8qxq1ahxp8610n799pd7a9kqg3liy7xq2pjvvp71x3cv";
  };

  # Man pages ship pre-generated in the tarball (Doc/*.1), so no yodl is needed.
  nativeBuildInputs = [ patchelf ];

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}

    # Shims: <langinfo.h> -- QNX has none, but zsh's multibyte support needs
    # nl_langinfo(CODESET) to pick the codeset (libbbnixcompat supplies the
    # symbol, deriving it from the environment). <wcwidth_compat.h> -- QNX's
    # <wchar.h> declares no wcwidth(3), which zsh calls via its WCWIDTH macro;
    # force-include the prototype (compat supplies the symbol) to avoid the
    # implicit declaration. See pkgs/files/{langinfo,wcwidth_compat}.h.
    mkdir -p shim
    cp ${./files/langinfo.h} shim/langinfo.h
    cp ${./files/wcwidth_compat.h} shim/wcwidth_compat.h

    # stddefFlag: the QNX size_t/unistd.h cross gap (qnx-common.nix). -I our
    # ncursesw headers + the shim dir. (SA_RESTART is left out: zsh #ifdef-guards
    # it, so it compiles without the define.)
    export CFLAGS="${qnx.stddefFlag} -include wcwidth_compat.h"
    export CPPFLAGS="${qnx.stddefFlag} -I$PWD/shim -I${ncurses}/include"
    # -L${compat}/lib so ld can resolve libncursesw.so's NEEDED libbbnixcompat.so.1.
    export LDFLAGS="-L${ncurses}/lib -L${compat}/lib"
    # -lncursesw: terminal (tgetent/terminfo). -liconv: QNX puts iconv in GNU
    # libiconv (libiconv.so.1), not libc; it resolves from the sysroot's
    # armle-v7/usr/lib exactly as -lsocket does, and its header macro-renames
    # iconv*->libiconv*, which zsh's configure handles natively. -lbbnixcompat:
    # zsh's own wcwidth/nl_langinfo calls (also makes AC_CHECK_FUNCS find them).
    export LIBS="-lncursesw -liconv -lbbnixcompat"

    # Cross cache vars: probes that compile AND RUN a target binary; we assert the
    # QNX/armle-v7 results directly (after Buildroot's zsh cross seed). armle-v7 is
    # ILP32, so long is 32-bit; off_t is 64-bit; the 64-bit type is long long.
    export zsh_cv_sys_nis=no
    export zsh_cv_sys_nis_plus=no
    export zsh_cv_long_is_64_bit=no
    export zsh_cv_off_t_is_64_bit=yes
    export zsh_cv_64_bit_type='long long'
    export zsh_cv_64_bit_utype='unsigned long long'
    export zsh_cv_printf_has_lld=yes
    # QNX defines struct timespec in <time.h>, but zsh's probe only checks
    # <sys/time.h> -- so it wrongly concludes "absent" and defines its own,
    # colliding with <time.h>. Assert the QNX truth.
    export zsh_cv_type_exists_struct_timespec=yes

    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --disable-dynamic \
      --enable-multibyte \
      --disable-gdbm \
      --enable-etcdir=/accounts/1000/shared/misc/etc/zsh
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  # STRIP=: disables zsh's install-time strip, which would run the host strip on
  # our ARM QNX ELFs ("Unable to recognise the architecture"). Pre-built man pages
  # and the Functions tree install cleanly.
  installPhase = ''
    runHook preInstall
    make install STRIP=:
    runHook postInstall
  '';

  # These are ARM/QNX target artifacts, so the default patchShebangs (which
  # rewrites a function's #!/bin/sh to the host build's bash store path) is both
  # meaningless and a /nix/store leak -- it would re-mangle `harden` *after* the
  # scrub below. Disable it; the deploy-bundle disables it for the same reason.
  dontPatchShebangs = true;

  # Ship NO RPATH: the device's QNX loader does not expand $ORIGIN, so deploy
  # sets LD_LIBRARY_PATH=<libdir>. install lays down bin/zsh + a bin/zsh-5.9
  # hardlink. See [[bbnix-openssh-userland]]. Done in postFixup (after the
  # fixupPhase) so nothing downstream re-introduces a store path.
  #
  # Same phase, scrub the build-prefix $out (a /nix/store path) out of the
  # shipped function tree so the deploy-bundle stays store-path-free
  # (checks/validate-bundle.sh rejects any /nix/store substring in a text
  # artifact). Two leak sites:
  #   - run-help/_run-help bake $out as the HELPDIR default; both honor $HELPDIR
  #     at runtime (the bundle re-seeds it relocatably), so drop the default.
  #   - harden carries a #!/nix/store/...-bash shebang; it's an autoloaded zsh
  #     function, never exec'd, so the shebang is cosmetic -> /bin/sh.
  # The guard makes a future zsh bump that bakes a new path fail here loudly
  # rather than later in flake-check.
  postFixup = ''
    for f in $out/bin/*; do
      patchelf --remove-rpath "$f"
    done

    fns=$out/share/zsh/${version}/functions
    sed -i 's#:-/nix/store/[^}]*/help}#:-}#' "$fns/run-help" "$fns/_run-help"
    sed -i '1s|^#!/nix/store/[^ ]*|#!/bin/sh|' "$fns/harden"
    if grep -rlI /nix/store "$out/share/zsh"; then
      echo "zsh.nix: unscrubbed /nix/store path in share/zsh (see above)" >&2
      exit 1
    fi
  '';

  meta = {
    description = "zsh ${version} cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
})
