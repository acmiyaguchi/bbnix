# SPDX-License-Identifier: MIT
# ncurses 6.4 cross-built from source for arm-unknown-nto-qnx8.0.0eabi
# (BlackBerry 10 / QNX 8 ARM). Wide-character build (libncursesw) -- the
# hard dependency for mosh-client and tmux, and the prerequisite for any
# UTF-8 TUI on-device.
#
# Two host/target splits make ncurses different from the other recipes:
#   - BUILD_CC: ncurses builds a few code-generator tools (make_hash, etc.)
#     that must RUN on the build host, separate from the target CC. We point
#     BUILD_CC at the host stdenv compiler.
#   - tic: `make install.data` compiles the terminfo source DB with `tic`,
#     which must also run on the host. We put a host ncurses' tic on PATH and
#     hand it to the build via TIC_PATH so the on-device terminfo DB is built.
{
  stdenv,
  lib,
  fetchurl,
  patchelf,
  buildPackages,
  binutils,
  gcc,
  compat,
  target ? "arm-unknown-nto-qnx8.0.0eabi",
  sysroot,
}:

let
  qnx = import ./qnx-common.nix { inherit gcc binutils target; };
  # Install (and bake as default) the terminfo DB under $out. On-device, deploy
  # ships this tree and points ncurses/mosh/tmux at it with TERMINFO=<dir> --
  # the same launch-env model as LD_LIBRARY_PATH (the baked /nix/store default
  # never resolves on the device, and TERMINFO overrides it anyway).
  terminfoDir = "$out/share/terminfo";
in
stdenv.mkDerivation (qnx.drvAttrs // rec {
  pname = "bbnix-ncurses";
  version = "6.4";

  src = fetchurl {
    url = "https://ftp.gnu.org/gnu/ncurses/ncurses-${version}.tar.gz";
    sha256 = "0nc14knjp080h6n06dpwnhmn68azqz290qhbydrm0z68k8yjhcb9";
  };

  # Host tooling: tic (compiles the terminfo DB) + a host C compiler for the
  # build-time code generators. These run on x86_64, not the target.
  nativeBuildInputs = [ patchelf buildPackages.ncurses ];

  configurePhase = ''
    runHook preConfigure
    ${qnx.crossEnv}
    export BUILD_CC=${buildPackages.stdenv.cc}/bin/cc
    export TIC_PATH=${buildPackages.ncurses}/bin/tic
    # stddefFlag: the QNX size_t/unistd.h cross gap (qnx-common.nix).
    export CFLAGS="${qnx.stddefFlag}"
    export CPPFLAGS="${qnx.stddefFlag}"

    # QNX's <sys/termio.h> is a deprecation stub that #errors if <termios.h>
    # was included first (its body lives under #ifndef _TERMIOS_H_INCLUDED).
    # ncurses includes both, so the legacy termio header is unusable here --
    # tell configure it is absent and let ncurses use termios (fully supported
    # on QNX) instead.
    export ac_cv_header_termio_h=no
    export ac_cv_header_sys_termio_h=no

    # QNX libc lacks the tsearch(3) tree-search family (it has hsearch only) and
    # does not provide/declare wcwidth(3). ncurses uses both unconditionally
    # (new_pair.c's ext-color cache; lib_wacs.c), so we supply them from
    # libbbnixcompat and put it on every link (the .so link via MK_SHARED_LIB
    # below, program links via LDFLAGS here). See pkgs/qnx-compat.nix.
    # --no-as-needed: -lbbnixcompat precedes the objects on the link line, so
    # an --as-needed default would drop the DT_NEEDED before the references are
    # seen. Force it to be recorded.
    export LDFLAGS="-L${compat}/lib -Wl,--no-as-needed -lbbnixcompat"

    ./configure \
      --host=${target} \
      --build=${stdenv.buildPlatform.config} \
      --prefix=$out \
      --with-shared --without-normal --without-debug \
      --enable-widec \
      --without-cxx-binding --without-ada \
      --without-tests --without-manpages \
      --disable-stripping \
      --enable-pc-files --with-pkg-config-libdir=$out/lib/pkgconfig \
      --with-default-terminfo-dir=${terminfoDir} \
      --with-terminfo-dirs=${terminfoDir}
    runHook postConfigure
  '';

  # ncurses doesn't recognise the nto-qnx host, so its shared-link rule falls
  # back to a generic `ld -Bshareable` -- which resolves to the *host* ld and
  # chokes on ARM objects ("relocations in generic ELF (EM: 40)"). Override
  # MK_SHARED_LIB to link through the cross gcc driver instead (also records
  # NEEDED libc.so.3, which a bare `ld` would omit). $@ is the target .so; it
  # must reach make literally, hence the single quotes. The driver does not
  # stamp a DT_SONAME here -- we set it in postFixup.
  mkSharedLib = "${gcc}/bin/${target}-gcc -shared -L${compat}/lib -Wl,--no-as-needed -lbbnixcompat -o $@";

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES MK_SHARED_LIB='${mkSharedLib}'
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    make install MK_SHARED_LIB='${mkSharedLib}'
    runHook postInstall
  '';

  # Set the versioned soname on each real .so (the cross gcc link above leaves
  # it bare, so anything linking -lncursesw would record the unversioned name),
  # and ship NO RPATH: the device's QNX loader does not expand $ORIGIN, so
  # deploy sets LD_LIBRARY_PATH=<libdir>. See [[bbnix-openssh-userland]].
  postFixup = ''
    for f in $out/lib/*.so.*.*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      soname="$(basename "$f")"; soname="''${soname%.*}"   # libfoo.so.6.4 -> libfoo.so.6
      patchelf --set-soname "$soname" "$f"
      patchelf --remove-rpath "$f"
    done
  '';

  meta = {
    description = "ncurses ${version} (widec) cross-built for BlackBerry 10 / QNX 8 ARM (${target})";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
})
