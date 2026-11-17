#!/usr/bin/env bash
# Cross-compile (if given C/C++ source) for QNX aarch64le, copy to the target and run it.
# Usage: deploy-run.sh <file.c|file.cpp|binary> [user@host] [-- program args...]
#   Defaults: target qnxuser@qnxpi.local, remote dir /tmp (override with REMOTE_DIR=...).
#   Extra compiler flags: CFLAGS="-O2 -Wall" LDLIBS="-lsocket"
set -euo pipefail
[ $# -ge 1 ] || { sed -n '2,6p' "$0"; exit 2; }
SRC=$1; shift
TARGET=qnxuser@qnxpi.local
if [ $# -gt 0 ] && [ "$1" != "--" ]; then TARGET=$1; shift; fi
[ $# -gt 0 ] && [ "$1" = "--" ] && shift
REMOTE_DIR=${REMOTE_DIR:-/tmp}
CFLAGS=${CFLAGS:--O2 -Wall}
LDLIBS=${LDLIBS:-}

if [ -z "${QNX_HOST:-}" ]; then
  env_script="${QNX_SDP_DIR:-$HOME/qnx800}/qnxsdp-env.sh"
  # shellcheck disable=SC1090
  [ -f "$env_script" ] && source "$env_script" >/dev/null || { echo "Source qnxsdp-env.sh first (or set QNX_SDP_DIR)"; exit 1; }
fi

case "$SRC" in
  *.c)   BIN=$(basename "${SRC%.c}");   qcc -Vgcc_ntoaarch64le $CFLAGS -o "$BIN" "$SRC" $LDLIBS ;;
  *.cpp|*.cc|*.cxx) BIN=$(basename "${SRC%.*}"); q++ -Vgcc_ntoaarch64le_cxx $CFLAGS -o "$BIN" "$SRC" $LDLIBS ;;
  *)     BIN=$SRC ;;
esac
echo ">> built/using $BIN; copying to $TARGET:$REMOTE_DIR"
scp -q "$BIN" "$TARGET:$REMOTE_DIR/"
echo ">> running on target"
ssh -t "$TARGET" "chmod +x '$REMOTE_DIR/$(basename "$BIN")' && '$REMOTE_DIR/$(basename "$BIN")' $*"
