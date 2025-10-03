#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  iMessage Exporter (imexporter) — Installer
#  Installs:
#   • App files in ~/Library/Application Support/messages_export_v2
#   • LaunchAgent (disabled by default)
#   • iCloud data folders (…/Documents/Social/Messaging/iMessage)
#   • Scriptable templates (into iCloud templates/)
#   • Creates index.json and _me/ on first run
# ============================================================

# -------- config defaults (do not hard-code tag here) --------
REPO="spcurtis81/imexporter"
TAG=""
APP_NS="messages_export_v2"
APP_DIR="$HOME/Library/Application Support/${APP_NS}"
LA_DIR="$HOME/Library/LaunchAgents"
LA_PLIST="${LA_DIR}/com.ste.${APP_NS}.plist"
RUNNER="${APP_DIR}/run_imexporter.sh"
CLI="${APP_DIR}/imexporter.py"

ICLOUD_BASE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/Social/Messaging/iMessage"
ICLOUD_TEMPLATES="${ICLOUD_BASE}/templates"
ICLOUD_AVATARS="${ICLOUD_BASE}/avatars"
ICLOUD_ME="${ICLOUD_BASE}/_me"
ICLOUD_INDEX_JSON="${ICLOUD_BASE}/index.json"

# Scriptable template filenames in repo
TEMPLATE_TODAY="scriptable/imessage_today_template.js"
TEMPLATE_TREND="scriptable/imessage_trend_template.js"
TEMPLATE_STATS="scriptable/imessage_stats_template.js"

# -------------------- small helpers -------------------------
cecho() { printf "%b\n" "$1"; }
ok()    { cecho "  [OK]  $1"; }
fail()  { cecho "  [FAIL] $1"; exit 1; }
info()  { cecho "  [..]  $1"; }
rule()  { cecho "============================================================"; }

usage() {
  cat <<EOF
Usage: $0 --tag vX.Y.Z

Options:
  --tag   The Git tag/release to install from (required), e.g. v1.1.0

Examples:
  $0 --tag v1.1.0
EOF
}

# ---------------- parse args ----------------
if [[ $# -lt 2 ]]; then usage; exit 1; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) fail "Unknown argument: $1 (use --help)";;
  esac
done
[[ -z "${TAG}" ]] && fail "Please pass a Git tag, e.g. --tag v1.1.0"

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${TAG}"

# ---------------- preflight -----------------
rule
cecho "iMessage Exporter (imexporter) — Installer"
rule
cecho "This will:"
cecho "  • Create app & data folders (macOS + iCloud)"
cecho "  • Let you choose a Python interpreter"
cecho "  • Download the CLI and Scriptable templates from GitHub (pinned tag)"
cecho "  • Write a LaunchAgent (disabled by default)"
cecho "  • Print next steps, including Full Disk Access guidance"
rule
cecho "• Using pinned tag ${TAG}"

command -v curl >/dev/null 2>&1 || fail "curl not found"
ok "curl available"

# -------------- ensure folders --------------
info "Creating folders"
mkdir -p "${APP_DIR}"             || fail "Cannot create ${APP_DIR}"
mkdir -p "${LA_DIR}"              || fail "Cannot create ${LA_DIR}"
mkdir -p "${ICLOUD_BASE}"         || fail "Cannot create ${ICLOUD_BASE}"
mkdir -p "${ICLOUD_TEMPLATES}"    || fail "Cannot create ${ICLOUD_TEMPLATES}"
mkdir -p "${ICLOUD_AVATARS}"      || fail "Cannot create ${ICLOUD_AVATARS}"
mkdir -p "${ICLOUD_ME}"           || fail "Cannot create ${ICLOUD_ME}"
ok "App, LaunchAgents, and iCloud folders created"

# ----------- create index.json on first run ------------
if [[ ! -f "${ICLOUD_INDEX_JSON}" ]]; then
  info "Bootstrap index.json"
  NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat > "${ICLOUD_INDEX_JSON}" <<JSON
{
  "schema": 1,
  "updated_at": "${NOW}",
  "contacts": [],
  "meAvatar": "_me/avatar.png"
}
JSON
  ok "index.json created"
else
  ok "index.json already exists"
fi

# --------------- discover pythons ----------------
info "Scanning for python3 interpreters"
declare -a PY_PATHS=()
add_if_present() { [[ -x "$1" ]] && PY_PATHS+=("$1"); }
add_if_present "/opt/homebrew/bin/python3"
add_if_present "/usr/local/bin/python3"
add_if_present "/usr/bin/python3"
# fallback: anything on PATH
if command -v python3 >/dev/null 2>&1; then
  PATH_PY="$(command -v python3)"
  [[ " ${PY_PATHS[*]} " == *" ${PATH_PY} "* ]] || PY_PATHS+=("${PATH_PY}")
fi

if [[ ${#PY_PATHS[@]} -eq 0 ]]; then
  fail "No python3 interpreters found. Install via: brew install python"
fi

cecho
cecho "Available python3 interpreters:"
for i in "${!PY_PATHS[@]}"; do
  idx=$((i+1))
  cecho "  ${idx}) ${PY_PATHS[$i]}"
done

read -rp "Select one (1-${#PY_PATHS[@]}) [1]: " SEL
SEL="${SEL:-1}"
if ! [[ "$SEL" =~ ^[0-9]+$ ]] || (( SEL < 1 || SEL > ${#PY_PATHS[@]} )); then
  fail "Invalid selection."
fi
PYTHON="${PY_PATHS[$((SEL-1))]}"
ok "Chosen python: ${PYTHON}"

# --------------- download helper ----------------
download_checked() {
  local url="$1" dest="$2" label="$3"
  info "Downloading ${label}"
  curl -fsSL "${url}" -o "${dest}" || fail "Download failed: ${label}"
  # ensure non-empty
  if [[ ! -s "${dest}" ]]; then
    fail "Downloaded file is empty: ${label} (${dest})"
  fi
  ok "Downloaded ${label}"
}

# ------------------ fetch files ------------------
download_checked "${RAW_BASE}/imexporter.py"                  "${CLI}"      "CLI app (imexporter.py)"
download_checked "${RAW_BASE}/scripts/run_imexporter.sh"      "${RUNNER}"   "Runner script"
download_checked "${RAW_BASE}/scripts/com.ste.${APP_NS}.plist" "${LA_PLIST}" "LaunchAgent plist"

chmod +x "${RUNNER}"

# --------- scriptable templates to iCloud --------
download_checked "${RAW_BASE}/${TEMPLATE_TODAY}" "${ICLOUD_TEMPLATES}/imessage_today_template.js" "Scriptable: Today template"
download_checked "${RAW_BASE}/${TEMPLATE_TREND}" "${ICLOUD_TEMPLATES}/imessage_trend_template.js" "Scriptable: Trend template"
download_checked "${RAW_BASE}/${TEMPLATE_STATS}" "${ICLOUD_TEMPLATES}/imessage_stats_template.js"  "Scriptable: Stats template"

# --------------- write runner header ---------------
# (ensure chosen python is used by the runner if the repo script is generic)
if ! grep -q "${PYTHON}" "${RUNNER}" 2>/dev/null; then
  # Prefix the runner with the selected interpreter if not already handled.
  # We keep the original content after a marker.
  TMP_RUN="${RUNNER}.tmp.$$"
  {
    echo "#!/usr/bin/env bash"
    echo "set -euo pipefail"
    echo "PYTHON=\"${PYTHON}\""
    echo 'exec "$PYTHON" "'"${CLI}"'" "$@"'
  } > "${TMP_RUN}"
  chmod +x "${TMP_RUN}"
  mv "${TMP_RUN}" "${RUNNER}"
  ok "Runner updated to use: ${PYTHON}"
fi

# ---------------- summary ----------------
cecho
rule
cecho "Installation Summary"
rule
printf "Tag:           %s\n" "${TAG}"
printf "Python:        %s\n" "${PYTHON}"
printf "CLI:           %s\n" "${CLI}"
printf "Runner:        %s\n" "${RUNNER}"
printf "LaunchAgent:   %s\n" "${LA_PLIST}"
printf "iCloud base:   %s\n" "${ICLOUD_BASE}"
printf "Templates:     %s\n" "${ICLOUD_TEMPLATES}"
printf "Avatars:       %s\n" "${ICLOUD_AVATARS}"
printf "Index JSON:    %s\n" "${ICLOUD_INDEX_JSON}"
rule

cat <<'TXT'
Next steps:
  1) Grant "Full Disk Access" to your chosen Python and Terminal/iTerm
     System Settings → Privacy & Security → Full Disk Access
     Add: the Python path shown above, and your terminal app.

  2) Run the CLI once to configure:
       "$HOME/Library/Application Support/messages_export_v2/run_imexporter.sh" --menu

  3) In Scriptable (iOS):
       • Create a File Bookmark pointing to your iCloud folder:
           Social/Messaging/iMessage
       • Duplicate a template from iCloud/templates/ and replace the PHONE placeholder.
       • Add the widget to your Home Screen and choose the new script.

  4) (Optional) Enable the LaunchAgent after you’re happy:
       launchctl load  -w "$HOME/Library/LaunchAgents/com.ste.messages_export_v2.plist"
       launchctl start    com.ste.messages_export_v2
     To disable:
       launchctl unload -w "$HOME/Library/LaunchAgents/com.ste.messages_export_v2.plist"

Done.
TXT
