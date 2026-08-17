#!/usr/bin/env bash
# Installs the optional on-demand aria2 layer:
#
#   ~/.local/bin/aria2ctl                       lifecycle + RPC helper
#   ~/.config/systemd/user/aria2.service        the daemon (NOT enabled at boot)
#   ~/.config/systemd/user/aria2-idle.service   idle check
#   ~/.config/systemd/user/aria2-idle.timer     runs the check while aria2 is up
#
# The plugin works fine without any of this — it just talks to whatever aria2 is
# already running. Install this only if you want the daemon to come and go with
# the queue.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"
UNITS=(aria2.service aria2-idle.service aria2-idle.timer)

uninstall() {
  # Stop the timer explicitly. PartOf= only propagates a stop when a stop job
  # actually runs, so a timer left active by a service that failed to start
  # would survive this and keep firing a script we are about to delete.
  systemctl --user stop aria2-idle.timer aria2-idle.service 2>/dev/null || true
  systemctl --user stop aria2.service 2>/dev/null || true
  systemctl --user reset-failed aria2.service 2>/dev/null || true
  local u
  for u in "${UNITS[@]}"; do rm -fv "${UNIT_DIR}/${u}"; done
  rm -fv "${BIN_DIR}/aria2ctl"
  systemctl --user daemon-reload
  echo "Removed. Your aria2 config and downloads were left alone."
}

install_all() {
  command -v aria2c >/dev/null || {
    echo "error: aria2c not found. Install aria2 first." >&2; exit 1; }
  # aria2ctl hard-requires both of these for its RPC calls.
  local dep
  for dep in curl python3; do
    command -v "$dep" >/dev/null || {
      echo "error: $dep not found; aria2ctl requires it." >&2; exit 1; }
  done

  mkdir -p "$BIN_DIR" "$UNIT_DIR"
  install -Dm755 "${HERE}/aria2ctl" "${BIN_DIR}/aria2ctl"
  local u
  for u in "${UNITS[@]}"; do
    install -Dm644 "${HERE}/${u}" "${UNIT_DIR}/${u}"
  done
  systemctl --user daemon-reload

  echo "Installed:"
  echo "  ${BIN_DIR}/aria2ctl"
  for u in "${UNITS[@]}"; do echo "  ${UNIT_DIR}/${u}"; done
  echo
  echo "aria2.service is intentionally NOT enabled — it starts on demand."
  echo
  echo "Next:"
  echo "  omarchy bar set io.github.rawritude.aria2 manageDaemon true --json"
  echo
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) echo "note: ${BIN_DIR} is not on your PATH; the plugin invokes aria2ctl"
       echo "      by absolute path, so this only affects using it by hand." ;;
  esac
  [ -f "${HOME}/.config/aria2/aria2.conf" ] || {
    echo "warning: no ~/.config/aria2/aria2.conf — aria2c will fail to start"
    echo "         until you create one. See the README for a minimal config."; }
  [ -f "${HOME}/.local/share/ariang/index.html" ] || {
    echo "note: no AriaNg at ~/.local/share/ariang/index.html — the 'open web UI'"
    echo "      action will do nothing until you drop the all-in-one build there."; }
}

case "${1:-}" in
  --uninstall|-u) uninstall ;;
  ""|--install)   install_all ;;
  *) echo "usage: $0 [--install|--uninstall]" >&2; exit 2 ;;
esac
