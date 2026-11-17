#!/usr/bin/env bash
# Verify a QNX SDP 8.0 host setup, and optionally an SSH-reachable target.
# Usage: check-host.sh [SDP_DIR] [user@target]
#   SDP_DIR defaults to $QNX_SDP_DIR, then ~/qnx800.
#   user@target (optional), e.g. qnxuser@qnxpi.local
set -u
SDP_DIR="${1:-${QNX_SDP_DIR:-$HOME/qnx800}}"
TARGET="${2:-}"
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAILED=1; }
warn() { printf '  [WARN] %s\n' "$*"; }
FAILED=0

echo "== Host"
arch=$(uname -m)
[ "$arch" = "x86_64" ] && ok "x86_64 host" || bad "host is $arch (SDP 8.0 needs x86_64)"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "  OS: ${PRETTY_NAME:-unknown} (officially supported: Ubuntu 22.04/20.04, RHEL 9)"; fi

echo "== SDP"
if [ -z "${QNX_HOST:-}" ]; then
  if [ -f "$SDP_DIR/qnxsdp-env.sh" ]; then
    # shellcheck disable=SC1091
    source "$SDP_DIR/qnxsdp-env.sh" >/dev/null 2>&1 && ok "sourced $SDP_DIR/qnxsdp-env.sh" || bad "failed to source env script"
  else
    bad "no qnxsdp-env.sh in $SDP_DIR (install SDP 8.0 with QNX Software Center, or pass its path)"
  fi
else
  ok "environment already set (QNX_HOST=$QNX_HOST)"
fi
[ -n "${QNX_TARGET:-}" ] && ok "QNX_TARGET=$QNX_TARGET" || bad "QNX_TARGET not set"

if command -v qcc >/dev/null 2>&1; then
  ok "qcc found: $(command -v qcc)"
  out=$(qcc 2>&1); rc=$?
  case $rc in
    129|130|131|132|133) bad "qcc license error (exit $rc): $out — accept/deploy your license in myQNX" ;;
    *) echo "  qcc says: $out" ;;
  esac
  if qcc -V 2>&1 | grep -q gcc_ntoaarch64le; then ok "aarch64le target available (Raspberry Pi)"; else bad "gcc_ntoaarch64le target not listed by 'qcc -V'"; fi
  tmp=$(mktemp -d); printf 'int main(void){return 0;}\n' > "$tmp/t.c"
  if qcc -Vgcc_ntoaarch64le -o "$tmp/t" "$tmp/t.c" >/dev/null 2>&1; then ok "test compile for aarch64le succeeded"; else bad "test compile for aarch64le failed (run: qcc -Vgcc_ntoaarch64le -o t t.c)"; fi
  rm -rf "$tmp"
else
  bad "qcc not on PATH"
fi

img=$(find "$(dirname "$SDP_DIR")" -maxdepth 4 -name 'qnx_sdp8.0_rpi*_quickstart_*.img' 2>/dev/null | head -1)
[ -n "$img" ] && ok "quick start image: $img" || warn "no Raspberry Pi quick start image found (install com.qnx.qnx800.quickstart.rpi4)"
command -v rpi-imager >/dev/null 2>&1 && ok "rpi-imager installed" || warn "rpi-imager not installed (sudo snap install rpi-imager)"
command -v cmake >/dev/null 2>&1 && echo "  cmake: $(cmake --version | head -1) (VS Code toolkit template wants >= 3.24)"
command -v code >/dev/null 2>&1 && { code --list-extensions 2>/dev/null | grep -qi '^qnx.qnx-vscode$' && ok "QNX Toolkit VS Code extension installed" || warn "QNX Toolkit extension not installed (code --install-extension qnx.qnx-vscode)"; }

if [ -n "$TARGET" ]; then
  echo "== Target $TARGET"
  host=${TARGET#*@}
  if ping -c1 -W2 "$host" >/dev/null 2>&1; then ok "ping $host"; else warn "no ping reply from $host (mDNS may be blocked; try the IP)"; fi
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$TARGET" 'uname -a' 2>/dev/null; then ok "ssh works"
  else warn "ssh with keys failed (try: ssh $TARGET ; default password qnxuser; then ssh-copy-id $TARGET)"; fi
fi

echo
[ $FAILED -eq 0 ] && echo "All required checks passed." || { echo "Some checks failed."; exit 1; }
