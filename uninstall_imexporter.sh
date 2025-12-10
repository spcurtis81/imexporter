#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# iMessage Exporter (imexporter) — Uninstaller
# Allows you to remove the app (scripts, LaunchAgent, logs) and optionally
# delete the iCloud data used by dashboards/widgets.
#
# Usage:
#   ./uninstall_imexporter.sh
# ============================================================================

APP_DIR="${HOME}/Library/Application Support/imexporter"
LOG_DIR="${HOME}/Library/Logs"
LAUNCH_PLIST="${HOME}/Library/LaunchAgents/com.ste.imexporter.plist"
RUNNER="${APP_DIR}/run_imexporter.sh"

ICLOUD_BASE="${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
ICLOUD_APP_DIR="${ICLOUD_BASE}/Documents/Social/Messaging/iMessage"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

echo "============================================================"
bold "iMessage Exporter (imexporter) — Uninstaller"
echo "============================================================"
echo
echo "This will remove the imexporter app from this Mac."
echo
echo "You can choose to:"
echo "  1) Remove app files only (recommended)"
echo "  2) Remove app files AND iCloud data (messages JSON/CSV/rollups)"
echo "  0) Cancel"
echo

read -r -p "Select an option [0/1/2]: " choice

case "$choice" in
  0|"")
    echo "Cancelled."
    exit 0
    ;;
  1)
    MODE="app-only"
    ;;
  2)
    MODE="app-and-data"
    ;;
  *)
    echo "Invalid choice. Aborting."
    exit 1
    ;;
esac

echo

# Extra warning if removing iCloud data
if [ "$MODE" = "app-and-data" ]; then
  red "WARNING: This will permanently delete iCloud data under:"
  echo "  ${ICLOUD_APP_DIR}"
  echo
  echo "Any dashboards, widgets, or other tools that read these JSON/CSV"
  echo "files will stop working once the data is removed."
  echo
  read -r -p "Type DELETE to confirm you want to remove the iCloud data: " confirm
  if [ "$confirm" != "DELETE" ]; then
    echo "Confirmation not given. Aborting."
    exit 1
  fi
fi

echo
echo "Stopping LaunchAgent (if loaded)..."
launchctl bootout "gui/$(id -u)/com.ste.imexporter" 2>/dev/null || true

echo "Removing LaunchAgent plist (if present)..."
rm -f "${LAUNCH_PLIST}"

echo "Removing app directory (if present)..."
rm -rf "${APP_DIR}"

echo "Removing runner shell (if present)..."
rm -f "${RUNNER}"

echo "Removing logs (if present)..."
rm -f "${LOG_DIR}/imexporter.out" "${LOG_DIR}/imexporter.err"

if [ "$MODE" = "app-and-data" ]; then
  echo "Removing iCloud data directory (if present)..."
  rm -rf "${ICLOUD_APP_DIR}"
fi

echo
green "Uninstall complete."

if [ "$MODE" = "app-only" ]; then
  echo
  echo "Your iCloud data is still present at:"
  echo "  ${ICLOUD_APP_DIR}"
  echo "Downstream features (dashboards/widgets) will continue to work"
  echo "until you remove that data yourself."
fi