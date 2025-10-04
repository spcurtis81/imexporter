#!/usr/bin/env bash
# ============================================================================
# iMessage Exporter (imexporter) — Installer
# Portable (bash/zsh) – no 'mapfile', no bash-only traps.
# ============================================================================

set -euo pipefail

APP_NAME="imexporter"
ORG_ID="com.ste"                             # for LaunchAgent label
GH_USER="spcurtis81"
GH_REPO="imexporter"

# ---- Resolve key locations --------------------------------------------------
HOME_DIR="${HOME}"

APP_DIR="${HOME_DIR}/Library/Application Support/${APP_NAME}"
LAUNCH_AGENTS_DIR="${HOME_DIR}/Library/LaunchAgents"
LOG_OUT="${HOME_DIR}/Library/Logs/${APP_NAME}.out"
LOG_ERR="${HOME_DIR}/Library/Logs/${APP_NAME}.err"

ICLOUD_ROOT="${HOME_DIR}/Library/Mobile Documents/com~apple~CloudDocs/Documents"
IMSG_BASE="${ICLOUD_ROOT}/Social/Messaging/iMessage"
TEMPLATES_DIR="${IMSG_BASE}/templates"
ME_DIR="${IMSG_BASE}/_me"

RUNNER_SH="${APP_DIR}/run_${APP_NAME}.sh"
CLI_PY="${APP_DIR}/${APP_NAME}.py"
PLIST="${LAUNCH_AGENTS_DIR}/${ORG_ID}.${APP_NAME}.plist"
DESKTOP_SHORTCUT="${HOME_DIR}/Desktop/iMessage_Exporter.command"

# ---- Pretty printing helpers ------------------------------------------------
bold()  { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[32m%s\033[0m" "$*"; }
yellow(){ printf "\033[33m%s\033[0m" "$*"; }
red()   { printf "\033[31m%s\033[0m" "$*"; }

ok()    { printf "  %s %s\n" "$(green "[OK]")" "$*"; }
info()  { printf "  %s %s\n" "$(yellow "[..]")" "$*"; }
fail()  { printf "  %s %s\n" "$(red "[FAIL]")" "$*"; exit 1; }

# ---- Parse args -------------------------------------------------------------
TAG="${1:-}"
if [[ "${TAG:-}" == "--tag" ]]; then
  TAG="${2:-}"
  shift 2 || true
fi

if [[ -z "${TAG:-}" ]]; then
  echo "Usage: $0 --tag vX.Y.Z"
  exit 1
fi

echo "============================================================"
echo "$(bold "iMessage Exporter (imexporter) — Installer")"
echo "============================================================"
echo "This will:"
echo "  • Create app & data folders (macOS + iCloud)"
echo "  • Let you choose a Python interpreter"
echo "  • Download the CLI and Scriptable templates from GitHub (pinned tag)"
echo "  • Write a LaunchAgent (disabled by default)"
echo "  • Print next steps, including Full Disk Access guidance"
echo "============================================================"

echo "• Using pinned tag ${TAG}"

# ---- Preflight --------------------------------------------------------------
command -v curl >/dev/null 2>&1 || fail "curl not found"
ok "curl available"

# ---- Make folders -----------------------------------------------------------
info "Creating folders"
mkdir -p "${APP_DIR}" "${LAUNCH_AGENTS_DIR}" \
         "${IMSG_BASE}" "${TEMPLATES_DIR}" "${ME_DIR}"
: > "${LOG_OUT}"
: > "${LOG_ERR}"
ok "App, LaunchAgents, and iCloud folders created"

# ---- Bootstrap index.json if missing ---------------------------------------
info "Bootstrap index.json"
INDEX_JSON="${IMSG_BASE}/index.json"
if [[ ! -f "${INDEX_JSON}" ]]; then
  NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat > "${INDEX_JSON}" <<JSON
{
  "schema": 1,
  "updated_at": "${NOW}",
  "contacts": [],
  "meAvatar": "_me/avatar.png"
}
JSON
fi
ok "index.json created"

# ---- Find python interpreters (portable; prints list) ----------------------
info "Scanning for python3 interpreters"
# Collect unique python3 paths
PY_LIST=()
while IFS= read -r p; do
  [[ -z "${p}" ]] && continue
  # de-duplicate
  already=0
  for q in "${PY_LIST[@]}"; do [[ "$q" == "$p" ]] && already=1 && break; done
  [[ $already -eq 0 ]] && PY_LIST+=("$p")
done < <( command -v -a python3 2>/dev/null || true )

# Fallbacks
[[ ${#PY_LIST[@]} -eq 0 && -x /opt/homebrew/bin/python3 ]] && PY_LIST+=("/opt/homebrew/bin/python3")
[[ ${#PY_LIST[@]} -eq 0 && -x /usr/local/bin/python3   ]] && PY_LIST+=("/usr/local/bin/python3")
[[ ${#PY_LIST[@]} -eq 0 && -x /usr/bin/python3         ]] && PY_LIST+=("/usr/bin/python3")

if [[ ${#PY_LIST[@]} -eq 0 ]]; then
  fail "No python3 interpreter found. Please install via Homebrew: brew install python"
fi

echo "Available python3 interpreters:"
i=1
for p in "${PY_LIST[@]}"; do
  echo "  $i) \"$p\""
  i=$((i+1))
done

read -r -p "Select one (1–${#PY_LIST[@]}) [1]: " CHOICE
CHOICE="${CHOICE:-1}"
if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#PY_LIST[@]} )); then
  fail "Invalid choice"
fi
PYTHON="${PY_LIST[$((CHOICE-1))]}"
ok "Using ${PYTHON}"

# ---- Download helper (raw from GitHub tag) ---------------------------------
download_raw () {
  local rel_path="$1" dest="$2"
  local url="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${TAG}/${rel_path}"
  curl -fsSL "${url}" -o "${dest}" || fail "Download failed: ${url}"
}

# ---- Download CLI & templates ----------------------------------------------
info "Downloading CLI and templates from GitHub (${TAG})"
download_raw "imexporter.py" "${CLI_PY}"
chmod 0644 "${CLI_PY}"
ok "CLI downloaded → ${CLI_PY}"

# Scriptable templates (placeholders are fine if you haven't pushed them yet)
download_raw "templates/imessage_today.js"  "${TEMPLATES_DIR}/imessage_today.js"  || true
download_raw "templates/imessage_trend.js"  "${TEMPLATES_DIR}/imessage_trend.js"  || true
download_raw "templates/imessage_stats.js"  "${TEMPLATES_DIR}/imessage_stats.js"  || true
ok "Templates placed in ${TEMPLATES_DIR}"

# ---- Runner shell -----------------------------------------------------------
cat > "${RUNNER_SH}" <<SH
#!/usr/bin/env bash
set -euo pipefail
PY="${PYTHON}"
CLI="${CLI_PY}"
OUT="${LOG_OUT}"
ERR="${LOG_ERR}"

# pass through any args; default to --auto-run
ARGS="\${*:-"--auto-run"}"

"\${PY}" "\${CLI}" \${ARGS} >> "\${OUT}" 2>> "\${ERR}"
SH
chmod +x "${RUNNER_SH}"
ok "Runner created → ${RUNNER_SH}"

# ---- LaunchAgent (disabled by default) --------------------------------------
cat > "${PLIST}" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>${ORG_ID}.${APP_NAME}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNNER_SH}</string>
    <string>--auto-run</string>
  </array>

  <!-- StartInterval is managed by the CLI settings menu; installer leaves it disabled. -->
  <!-- <key>StartInterval</key> <integer>1800</integer> -->

  <key>StandardOutPath</key>  <string>${LOG_OUT}</string>
  <key>StandardErrorPath</key><string>${LOG_ERR}</string>
  <key>RunAtLoad</key>        <false/>
</dict>
</plist>
PL
ok "LaunchAgent written → ${PLIST}"
echo "  (Not loaded; manage it from inside the app’s settings menu.)"

# ---- Optional desktop shortcut ---------------------------------------------
cat > "${DESKTOP_SHORTCUT}" <<APP
#!/usr/bin/env bash
osascript -e 'display dialog "iMessage Exporter: run ad-hoc export now?" buttons {"Cancel","Run"} default button "Run"' \
  | grep -q "Run" && "${RUNNER_SH}" --run-now
APP
chmod +x "${DESKTOP_SHORTCUT}" || true
ok "Desktop shortcut created (optional) → ${DESKTOP_SHORTCUT}"

# ---- Summary ---------------------------------------------------------------
echo
echo "============================================================"
echo "$(bold "Installation Summary")"
echo "============================================================"
echo "Tag:               ${TAG}"
echo "Python:            ${PYTHON}"
echo "CLI:               ${CLI_PY}"
echo "Runner:            ${RUNNER_SH}"
echo "LaunchAgent:       ${PLIST}"
echo "Logs:              ${LOG_OUT} , ${LOG_ERR}"
echo "Data dir:          ${IMSG_BASE}"
echo "Templates:         ${TEMPLATES_DIR}"
echo "Me (avatar) dir:   ${ME_DIR}"
echo
echo "Next steps:"
echo "  1) Give ${APP_NAME} Full Disk Access (System Settings → Privacy & Security)."
echo "  2) Run the app once to configure:  ${green "${PYTHON} ${CLI_PY}"}"
echo "  3) Inside the app:"
echo "       • Add your first contact"
echo "       • (Optional) enable/adjust schedule (LaunchAgent)"
echo "       • Check config summary"
echo
echo "Done."
