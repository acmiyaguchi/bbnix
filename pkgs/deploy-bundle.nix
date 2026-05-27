# SPDX-License-Identifier: MIT
# deploy-bundle — a relocatable bin/ + lib/ + terminfo/ + CA tree assembled from
# the from-source userland, for Term50 to pin as a flake input and stage under
# app/native/bbnix (issue #4).
#
# Pure host-side assembly: it only copies already-built ARM ELFs (and the host
# CA bundle), so it needs no cross toolchain. The fixup hooks are disabled
# (dontStrip/dontPatchELF/dontPatchShebangs) because the payload is ARM, not
# host-native — the per-package recipes already set the correct sonames and ship
# no RPATH, so the loader finds libs via LD_LIBRARY_PATH=<root>/lib at launch.
#
# Variants nest minimal ⊂ ssh ⊂ full:
#   minimal  zsh + tmux + ncursesw + libbbnixcompat + terminfo
#   ssh      + ssh/scp/sftp/ssh-keygen + libssl/libcrypto/libz + CA bundle
#   full     + mosh-client + the mosh launcher + curl + libbtcrash (LD_PRELOAD)
{
  stdenv,
  lib,
  openssh,
  curl,
  mosh,
  tmux,
  zsh,
  btcrash,
  ncurses,
  openssl,
  zlib,
  compat,
  cacert,
  variant ? "full",
}:

let
  ranks = { minimal = 0; ssh = 1; full = 2; };
  rank = ranks.${variant} or (throw "deploy-bundle: unknown variant '${variant}' (want minimal|ssh|full)");
  hasSsh = rank >= ranks.ssh;
  hasFull = rank >= ranks.full;
in
stdenv.mkDerivation {
  pname = "bbnix-deploy-bundle-${variant}";
  version = "1";

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib $out/terminfo

    # minimal: interactive shell + multiplexer + their shared deps. tmux/zsh
    # statically embed libevent + all modules, so only ncursesw + the libc-gap
    # compat shim need shipping. cp -L derefs each soname symlink to a regular
    # file under that name (e.g. libncursesw.so.6 from libncursesw.so.6.4).
    cp ${zsh}/bin/zsh   $out/bin/
    cp ${tmux}/bin/tmux $out/bin/
    cp -L ${ncurses}/lib/libncursesw.so.6 $out/lib/
    cp -L ${compat}/lib/libbbnixcompat.so.1 $out/lib/
    cp -r ${ncurses}/share/terminfo/. $out/terminfo/

  '' + lib.optionalString hasSsh ''
    # ssh: OpenSSH client tools + the from-source crypto/zlib they link (the
    # device only has the EOL .so.2). These are the HTTPS-relevant libs, so the
    # CA bundle ships from here up.
    cp ${openssh}/bin/ssh ${openssh}/bin/scp ${openssh}/bin/sftp ${openssh}/bin/ssh-keygen $out/bin/
    cp -L ${openssl}/lib/libssl.so.3 ${openssl}/lib/libcrypto.so.3 $out/lib/
    cp -L ${zlib}/lib/libz.so.1.3.1 $out/lib/libz.so.1

    # WebPKI CA bundle from nixpkgs.cacert, in both the openssl-style and the
    # Debian-style location. Relocatable: a launcher points SSL_CERT_FILE /
    # CURL_CA_BUNDLE at $root/ssl/cacert.pem (not curl's baked device default).
    mkdir -p $out/ssl $out/etc/ssl/certs
    cp ${cacert}/etc/ssl/certs/ca-bundle.crt $out/ssl/cacert.pem
    cp ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt

  '' + lib.optionalString hasFull ''
    # full: mosh-client + its pure-shell launcher (resolves the bundle root from
    # $0 and auto-loads libbtcrash.so when present), plus the static curl CLI.
    cp ${mosh}/bin/mosh-client ${mosh}/bin/mosh $out/bin/
    cp ${curl}/bin/curl $out/bin/
    cp -L ${btcrash}/lib/libbtcrash.so $out/lib/

  '' + ''
    # Store sources are read-only; make the staged tree writable for callers.
    chmod -R u+w $out
    runHook postInstall
  '';

  meta = {
    description = "Relocatable BB10/QNX userland deploy bundle (${variant}) for Term50";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
