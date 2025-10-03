#!/usr/bin/env bash
set -euo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; CLR=$'\033[0m'
OK="${GRN}[OK]${CLR}"; MISS="${GRN}[GONE]${CLR}"; WARN="${YLW}[LEFTOVER]${CLR}"; ERR="${RED}[ERROR]${CLR}"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1 && echo "${YLW}--purge enabled: will delete leftovers${CLR}"

echo "🔎 Checking for old imexporter installs & artifacts..."
echo

leftovers=0

# Known app dirs (old/new variants you’ve used during development)
APP_DIRS=(
  "$HOME/Library/Application Support/messages_export_v2"
  "$HOME/Library/Application Support/messages_export"
  "$HOME/Library/Application Support/messages_export_v3"
  "$HOME/Library/Application Support/messages_exporter"
)

# LaunchAgents we used / may have used
LAUNCH_AGENTS=(
  "$HOME/Library/LaunchAgents/com.ste.imexporter.plist"
  "$HOME/Library/LaunchAgents/com.ste.messages_export.plist"
  "$HOME/Library/LaunchAgents/com.ste.messages_export_v2.plist"
)

# Logs
LOG_FILES=(
  "$HOME/Library/Logs/imexporter.log"
  "$HOME/Library/Logs/messages_export.out"
  "$HOME/Library/Logs/messages_export.err"
)

# Possible Python runner locations from your notes
PY_RUNNERS=(
  "/opt/homebrew/bin/python3"
  "/usr/local/bin/python3"
  "/usr/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.9/bin/python3"
)

# 1) LaunchAgents loaded?
echo "▪ launchd jobs:"
for lbl in com.ste.imexporter com.ste.messages_export com.ste.messages_export_v2; do
  if launchctl list | grep -q "$lbl"; then
    echo "  ${WARN} loaded: $lbl"
    ((leftovers++))
    if (( PURGE )); then
      launchctl bootout "gui/$(id -u)/$lbl" 2>/dev/null || true
      echo "     ${OK} booted out: $lbl"
    fi
  else
    echo "  ${OK} not loaded: $lbl"
  fi
done
echo

# 2) LaunchAgent plists on disk?
echo "▪ LaunchAgent files:"
for p in "${LAUNCH_AGENTS[@]}"; do
  if [[ -f "$p" ]]; then
    echo "  ${WARN} exists: $p"
    ((leftovers++))
    if (( PURGE )); then
      launchctl unload "$p" 2>/dev/null || true
      rm -f "$p" && echo "     ${OK} removed $p"
    fi
  else
    echo "  ${MISS} $p"
  fi
done
echo

# 3) App directories
echo "▪ App support directories:"
for d in "${APP_DIRS[@]}"; do
  if [[ -d "$d" ]]; then
    echo "  ${WARN} exists: $d"
    ((leftovers++))
    if (( PURGE )); then
      rm -rf "$d" && echo "     ${OK} removed $d"
    fi
  else
    echo "  ${MISS} $d"
  fi
done
echo

# 4) Logs
echo "▪ Log files:"
for f in "${LOG_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    echo "  ${WARN} exists: $f"
    ((leftovers++))
    if (( PURGE )); then
      rm -f "$f" && echo "     ${OK} removed $f"
    fi
  else
    echo "  ${MISS} $f"
  fi
done
echo

# 5) iCloud data folders (heads-up only; you said you’re backing up by renaming)
echo "▪ iCloud data (heads-up only; NOT deleted automatically):"
ICLOUD_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/Social/Messaging"
if [[ -d "$ICLOUD_ROOT" ]]; then
  # list immediate children to show what’s there
  echo "  ${OK} base exists: $ICLOUD_ROOT"
  echo "  ${DIM}contents:${CLR}"
  ls -1 "$ICLOUD_ROOT" | sed 's/^/    - /'
else
  echo "  ${MISS} $ICLOUD_ROOT"
fi
echo

# 6) Quick sweep for old filenames (non-fatal)
echo "▪ Quick filename sweep (home dir):"
FOUND=$( (command -v rg >/dev/null && rg -uu --hidden --ignore-case --no-messages -n \
  'imexporter|messages_export(_v2)?|com\.ste\.imexporter|com\.ste\.messages_export' "$HOME") || true )
if [[ -n "$FOUND" ]]; then
  echo "  ${WARN} potential refs in files under ~"
  echo "$FOUND" | sed 's/^/    /'
else
  echo "  ${OK} no obvious refs in ~ (quick scan)"
fi
echo

# 7) Python runners (just info)
echo "▪ Python runners on system:"
for py in "${PY_RUNNERS[@]}"; do
  if [[ -x "$py" ]]; then
    echo "  ${OK} $py"
  fi
done
echo

# Summary
if (( leftovers > 0 )); then
  if (( PURGE )); then
    echo "${OK} purge completed. re-run this script without --purge to verify it's clean."
  else
    echo "${WARN} found $leftovers leftover item(s). run again with --purge to remove."
    exit 2
  fi
else
  echo "${OK} no leftovers detected. system looks clean."
fi
