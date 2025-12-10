#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# iMessage Exporter (imexporter) — Installer
# Creates app folders (macOS + iCloud), lets you pick python3, installs CLI
# and dashboard templates (from local repo if present, else from GitHub),
# writes a LaunchAgent (disabled by default), and prints next steps.
#
# Usage:
#   ./install_imexporter.sh [--tag v1.2.3]
# ============================================================================

# ---------- Config (change only if you fork/rename) -------------------------
REPO_USER="spcurtis81"
REPO_NAME="imexporter"

APP_DIR="${HOME}/Library/Application Support/imexporter"
LOG_DIR="${HOME}/Library/Logs"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENTS}/com.ste.imexporter.plist"

# iCloud base + app paths
ICLOUD_BASE="${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
ICLOUD_APP_DIR="${ICLOUD_BASE}/Documents/Social/Messaging/iMessage"
ICLOUD_TEMPLATES_DIR="${ICLOUD_APP_DIR}/templates"
ICLOUD_ME_DIR="${ICLOUD_APP_DIR}/_me"
ICLOUD_INDEX_JSON="${ICLOUD_APP_DIR}/index.json"

DESKTOP_SHORTCUT="${HOME}/Desktop/imexporter.sh"

# ---------- Helpers ---------------------------------------------------------
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }

die() {
  red "ERROR: $*"
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

url_for() {
  local path="$1"
  local tag="${TAG:-}"
  if [ -n "${tag}" ]; then
    echo "https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/${tag}/${path}"
  else
    echo "https://raw.githubusercontent.com/${REPO_USER}/${REPO_NAME}/main/${path}"
  fi
}

# ---------- Parse arguments -------------------------------------------------
TAG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      TAG="$2"
      shift 2
      ;;
    --tag=*)
      TAG="${1#*=}"
      shift 1
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

# ---------- Pre-flight checks ----------------------------------------------
need curl
need python3 || true  # we handle no-python case later

echo "============================================================"
bold "iMessage Exporter (imexporter) — Installer"
echo "============================================================"
echo

# ---------- Create folders --------------------------------------------------
echo "  [..]  Creating app folders"
mkdir -p "${APP_DIR}" "${LAUNCH_AGENTS}" "${LOG_DIR}" \
         "${ICLOUD_APP_DIR}" "${ICLOUD_TEMPLATES_DIR}" "${ICLOUD_ME_DIR}"
echo "  [OK]  App, LaunchAgents, and iCloud folders created"

CLI_DST="${APP_DIR}/imexporter.py"
RUNNER_DST="${APP_DIR}/run_imexporter.sh"

# ---------- Initial index.json ---------------------------------------------
if [ ! -f "${ICLOUD_INDEX_JSON}" ]; then
  echo "  [..]  Creating initial index.json"
  cat > "${ICLOUD_INDEX_JSON}" <<EOF
{
  "contacts": []
}
EOF
  echo "  [OK]  index.json created"
else
  echo "  [OK]  index.json exists"
fi

# Remove legacy root avatars folder if present (we no longer use it)
if [ -d "${ICLOUD_APP_DIR}/avatars" ]; then
  echo "  [OK]  removed legacy iMessage/avatars/ (no longer used)"
  rm -rf "${ICLOUD_APP_DIR}/avatars" || true
fi

# ---------- Discover python3 interpreters (Bash 3.2 compatible) ------------
echo "  [..]  Scanning for python3 interpreters"
PY_LIST=()
if command -v python3 >/dev/null 2>&1; then
  PY_LIST+=("$(command -v python3)")
fi
# Common Homebrew + system locations
for p in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -x "$p" ] && [[ ! " ${PY_LIST[*]} " =~ " $p " ]]; then
    PY_LIST+=("$p")
  fi
done

if [ "${#PY_LIST[@]}" -eq 0 ]; then
  die "No python3 interpreters found. Install Python 3 via Homebrew or Xcode tools."
fi

echo "Available python3 interpreters:"
i=1
for py in "${PY_LIST[@]}"; do
  echo "  $i) $py"
  i=$((i+1))
done

read -r -p "Select python3 [1]: " choice
choice="${choice:-1}"
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#PY_LIST[@]}" ]; then
  die "Invalid selection."
fi
PYTHON_BIN="${PY_LIST[$((choice-1))]}"

echo "  [OK]  Using python3 at: $(green "${PYTHON_BIN}")"

# ---------- Install CLI & templates ----------------------------
echo "  [..]  Installing CLI and templates"

if [ -f "./imexporter.py" ]; then
  echo "  [OK]  Found local imexporter.py in current directory"
  cp "./imexporter.py" "${CLI_DST}"
  chmod +x "${CLI_DST}"
  echo "  [OK]  Copied imexporter.py to ${CLI_DST}"

  # Templates from ./templates if present
  for f in imessage_today.js imessage_trend.js imessage_stats.js; do
    if [ -f "./templates/${f}" ]; then
      cp "./templates/${f}" "${ICLOUD_TEMPLATES_DIR}/${f}"
      echo "  [OK]  Installed templates/${f} from local templates/"
    else
      echo "  [WARN] templates/${f} not found locally; skipping"
    fi
  done
else
  echo "  [..]  No local imexporter.py found, downloading from GitHub ${TAG:+(}${TAG:-}(tag)${TAG:+)}"
  # CLI from GitHub
  CLI_URL="$(url_for 'imexporter.py')"
  curl -fsSL "${CLI_URL}" -o "${CLI_DST}" || die "Download failed: ${CLI_URL}"
  chmod +x "${CLI_DST}"

  # Templates from GitHub (raw files in repo root /scriptable/)
  for f in imessage_today.js imessage_trend.js imessage_stats.js; do
    SRC_URL="$(url_for "scriptable/${f}")"
    curl -fsSL "${SRC_URL}" -o "${ICLOUD_TEMPLATES_DIR}/${f}" || die "Download failed: ${SRC_URL}"
  done
fi

echo "  [OK]  CLI & templates installed"

# ---------- Runner shell for LaunchAgent & manual runs ---------------------
cat > "${RUNNER_DST}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
PY="${PYTHON_BIN}"
exec "\${PY}" "${CLI_DST}" --auto-run >> "${LOG_DIR}/imexporter.out" 2>> "${LOG_DIR}/imexporter.err"
EOF
chmod +x "${RUNNER_DST}"

# ---------- LaunchAgent (disabled by default) ------------------------------
cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.ste.imexporter</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNNER_DST}</string>
  </array>
  <key>RunAtLoad</key>        <false/>
  <key>StartInterval</key>    <integer>1800</integer>
  <key>StandardOutPath</key>  <string>${LOG_DIR}/imexporter.out</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/imexporter.err</string>
</dict>
</plist>
EOF

# ---------- Optional Desktop shortcut -------------------------------------
cat > "${DESKTOP_SHORTCUT}" <<EOF
#!/usr/bin/env bash
open -a Terminal "${RUNNER_DST}"
EOF
chmod +x "${DESKTOP_SHORTCUT}"

# ---------- Summary --------------------------------------------------------
echo
echo "============================================================"
echo "$(bold 'Installation Summary')"
echo "============================================================"
echo "Tag:            ${TAG:-local/main}"
echo "Python:         ${PYTHON_BIN}"
echo "CLI:            ${CLI_DST}"
echo "Runner:         ${RUNNER_DST}"
echo "LaunchAgent:    ${PLIST_PATH}"
echo "Logs:           ${LOG_DIR}/imexporter.out , ${LOG_DIR}/imexporter.err"
echo "Data dir:       ${ICLOUD_APP_DIR}"
echo "Templates:      ${ICLOUD_TEMPLATES_DIR}"
echo "Me (avatar) dir:${ICLOUD_ME_DIR}"
echo
echo "Next steps:"
echo "  1) Give imexporter Full Disk Access (System Settings → Privacy & Security)."
echo "  2) Run the app once to configure:"
echo "     $(green "\"${PYTHON_BIN}\" \"${CLI_DST}\"")"
echo "  3) Use the app’s Settings menu to enable/disable the LaunchAgent and set frequency."
echo
echo "Done."