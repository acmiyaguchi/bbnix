#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# bbnix deploy-bundle validation (pkgs/deploy-bundle.nix).
#
# Usage: validate-bundle.sh <binutils-prefix> <bundle-dir>
#   binutils-prefix  result of .#binutils (provides target readelf)
#   bundle-dir       a built .#deploy-bundle{,-minimal,-ssh,-full} tree
#
# Asserts the staged tree is what Term50 can drop into app/native/bbnix:
#   - every bin/ ELF is a BB10/QNX armle-v7 executable, every lib/ .so a library
#     (delegated to the sibling validate-elf.sh: interp, NEEDED, no .so.2/glibc,
#     no /nix/store RUNPATH);
#   - no /nix/store leak in any text artifact (scripts/configs) and no symlink
#     pointing into the store (the recipe derefs sonames with cp -L);
#   - terminfo/ is populated with an xterm-256color entry;
#   - when the OpenSSH client is present (ssh/full), the relocatable CA bundle
#     ships at ssl/cacert.pem and etc/ssl/certs/ca-certificates.crt.
set -euo pipefail

BU_PREFIX="${1:?binutils prefix}"
# Resolve to the physical path so a `nix build -o result` gc-root symlink isn't
# itself flagged by the in-tree symlink scan below.
BUNDLE="$(cd "${2:?bundle dir}" && pwd -P)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE_ELF="$HERE/validate-elf.sh"

[ -x "$VALIDATE_ELF" ] || { echo "FAIL: missing sibling validate-elf.sh"; exit 1; }

# ELF magic (\x7fELF) without depending on file(1), which isn't on the check
# sandbox PATH. od is coreutils.
is_elf() { [ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' ')" = "7f454c46" ]; }

echo "== deploy-bundle: $BUNDLE =="

# 1. Per-artifact ELF checks. bin/ holds executables (including the sh-launcher
#    ELF shipped as bin/mosh - issue #6); lib/ holds shared objects.
#    validate-elf.sh exits non-zero on any failure, which aborts us under set -e.
shopt -s nullglob
for f in "$BUNDLE"/bin/*; do
  if is_elf "$f"; then
    bash "$VALIDATE_ELF" "$BU_PREFIX" "$f" exe
  else
    echo "-- skip non-ELF $f (launcher script)"
  fi
done

# If mosh ships, require the issue #6 layout: bin/mosh is the ELF trampoline and
# libexec/mosh is the real shell sidecar. Key off mosh-client so dropping both
# launcher files cannot silently skip this check.
if [ -e "$BUNDLE/bin/mosh-client" ]; then
  is_elf "$BUNDLE/bin/mosh" || { echo "FAIL: bin/mosh is not an ELF (issue #6)"; exit 1; }
  [ -s "$BUNDLE/libexec/mosh" ] || { echo "FAIL: missing/empty libexec/mosh sidecar (issue #6)"; exit 1; }
  echo "  mosh launcher (ELF + libexec sidecar) OK"
fi
for f in "$BUNDLE"/lib/*.so*; do
  bash "$VALIDATE_ELF" "$BU_PREFIX" "$f" lib
done

# 2. No /nix/store leak. -I limits the scan to text artifacts (scripts/configs):
#    unstripped ARM ELFs carry DWARF build paths that are not runtime
#    assumptions, and validate-elf.sh already proved their RUNPATH is clean.
if grep -rlI /nix/store "$BUNDLE"; then
  echo "FAIL: /nix/store path in a text artifact above"; exit 1
fi
# The recipe derefs sonames with cp -L, so the tree should hold no symlinks at
# all — certainly none into the store.
while IFS= read -r link; do
  tgt="$(readlink "$link")"
  case "$tgt" in
    /nix/store/*) echo "FAIL: symlink into store: $link -> $tgt"; exit 1 ;;
  esac
done < <(find "$BUNDLE" -type l)

# 3. terminfo DB present with the default 256-color entry.
[ -d "$BUNDLE/terminfo" ] || { echo "FAIL: no terminfo/"; exit 1; }
find "$BUNDLE/terminfo" -name 'xterm-256color' -print -quit | grep -q . \
  || { echo "FAIL: terminfo/ has no xterm-256color entry"; exit 1; }
echo "  terminfo OK"

# 4. A bundle that ships the from-source TLS stack (libssl) must also carry the
#    relocatable trust store its HTTPS tools verify against — they travel
#    together in the ssh/full variants. Key off the lib, not an arbitrary tool.
if [ -e "$BUNDLE/lib/libssl.so.3" ]; then
  [ -s "$BUNDLE/ssl/cacert.pem" ] \
    || { echo "FAIL: missing/empty ssl/cacert.pem"; exit 1; }
  [ -s "$BUNDLE/etc/ssl/certs/ca-certificates.crt" ] \
    || { echo "FAIL: missing/empty etc/ssl/certs/ca-certificates.crt"; exit 1; }
  echo "  CA bundle OK"
fi

# 5. Activation contract (issue #8): both files ship in every variant. The
#    set-if-{file,dir} SSL_* entries no-op themselves on minimal where the
#    cert files are absent. Forced BBNIX_CODESET=UTF-8 is the load-bearing
#    tmux gate; assert its presence so a future edit can't silently downgrade
#    it to default/soft.
for f in etc/bbnix-env etc/bbnix-activate; do
  [ -s "$BUNDLE/$f" ] || { echo "FAIL: missing/empty $f"; exit 1; }
done
for forced in BBNIX_CODESET=UTF-8 LC_ALL=C; do
  grep -q "^set[[:space:]]\+${forced}[[:space:]]*\$" "$BUNDLE/etc/bbnix-env" \
    || { echo "FAIL: bbnix-env missing forced 'set $forced'"; exit 1; }
done

# Static checks for footguns that the host-side runtime smoke (which runs
# under bash) cannot catch -- the device's /bin/sh is an old ksh that
# (a) does NOT honor [[:class:]] POSIX character classes inside ${var%%pat*}
#     parameter-expansion patterns (treats them as a literal set of chars),
#     so any such pattern silently fails to match and the shim skips every
#     manifest line, and
# (b) has no `printf` builtin or pre-activation `/usr/bin/printf`, so any
#     $(printf ...) subshell in the activate fails *before* PATH is composed
#     -- silently dropping the existing PATH if used inside `prepend`.
# Both bugs were caught by on-device smoke against a Q10; these greps stop
# them from coming back.
if grep -vE '^[[:space:]]*#' "$BUNDLE/etc/bbnix-activate" | grep -n '\[\[:' >&2; then
  echo "FAIL: bbnix-activate uses [[:class:]] POSIX character classes -- not portable to QNX /bin/sh"
  exit 1
fi
if grep -vE '^[[:space:]]*#' "$BUNDLE/etc/bbnix-activate" \
   | grep -nE '\$\((printf|sed|awk|grep)' >&2; then
  echo "FAIL: bbnix-activate forks an external (printf/sed/awk/grep) -- not safe before PATH is composed"
  exit 1
fi

# Smoke-test the shim host-side. Seed a hostile inherited env (bad LC_ALL,
# wrong BBNIX_CODESET, dirty PATH/LD) to prove force/default/prepend each
# does what it says -- not just that the shim runs to completion. env -i
# scrubs everything else so any leaked default is the shim's own doing.
# Resolve sh before scrubbing -- /seed/bin in the seeded PATH won't have it.
SH="$(command -v sh)"
out=$(env -i HOME=/tmp \
          PATH=/seed/bin LD_LIBRARY_PATH=/seed/lib \
          LC_ALL=en_US.UTF-8 TMUX_TMPDIR=/seed/tmp TERM=seed-term \
          BBNIX_CODESET=BAD \
        "$SH" -c "BBNIX_ROOT='$BUNDLE' . '$BUNDLE/etc/bbnix-activate' && \
                  for v in BBNIX_CODESET TERMINFO PATH LD_LIBRARY_PATH \
                           LC_ALL TMUX_TMPDIR TERM SSL_CERT_FILE; do \
                    eval \"printf '%s=%s\\n' \\\"\$v\\\" \\\"\\\${\$v-<unset>}\\\"\"; \
                  done")

_assert_out() {
  case "$out" in *"$1"*) return 0 ;; esac
  echo "FAIL: $2"; echo "$out"; exit 1
}
_assert_out "BBNIX_CODESET=UTF-8"               "set BBNIX_CODESET did not overwrite inherited BAD"
_assert_out "LC_ALL=C"                          "set LC_ALL did not overwrite inherited en_US.UTF-8"
_assert_out "TERMINFO=$BUNDLE/terminfo"         "set TERMINFO not applied"
_assert_out "PATH=$BUNDLE/bin:/seed/bin"        "prepend PATH did not compose with /seed/bin"
_assert_out "LD_LIBRARY_PATH=$BUNDLE/lib:/seed/lib" "prepend LD_LIBRARY_PATH did not compose with /seed/lib"
for kv in "TMUX_TMPDIR=/seed/tmp" "TERM=seed-term"; do
  _assert_out "$kv" "default did not preserve inherited $kv"
done
# set-if-file: apply on ssh/full (cacert present), no-op on minimal.
if [ -f "$BUNDLE/ssl/cacert.pem" ]; then
  _assert_out "SSL_CERT_FILE=$BUNDLE/ssl/cacert.pem" \
    "set-if-file SSL_CERT_FILE not applied with cacert present"
else
  _assert_out "SSL_CERT_FILE=<unset>" \
    "set-if-file SSL_CERT_FILE leaked on minimal (no cacert)"
fi
echo "  activation manifest OK"

echo "== PASS ($BUNDLE) =="
