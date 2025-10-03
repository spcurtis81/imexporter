#!/bin/zsh
# install_imexporter.sh — Middle-ground installer (folders + fetch assets)
# MIT © Stephen Curtis

# ────────────────────────────────────────────────────────────────────────────
# CONFIG — edit these three for your repo/tag; add checksums when you publish
# ────────────────────────────────────────────────────────────────────────────
GH_OWNER="YOUR_GH_USERNAME"       # e.g. "spcurtis81"
GH_REPO="imexporter"              # repo name
RELEASE_TAG="v1.0.0"              # pinned tag for reproducible installs

# Optional SHA-256 checksums. Leave empty to skip verification.
# Fill these with real values from your release assets later.
typeset -A SHA256
SHA256[imexporter.py]=""
SHA256[imessage_today.js]=""
SHA256[imessage_trend.js]=""
SHA256[imessage_stats.js]=""

# ────────────────────────────────────────────────────────────────────────────
# PATHS (don’t usually need changing)
# ────────────────────────────────────────────────────────────────────────────
APP_DIR="$HOME/Library/Application Support/messages_export_v2"
RUNNER="$APP_DIR/run_imexporter.sh"
APP_PY="$APP_DIR/imexporter.py"
LOG_DIR="$HOME/Library/Logs"
LOG_OUT="$LOG_DIR/messages_export_v2.out"
LOG_ERR="$LOG_DIR/messages_export_v2.err"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/com.ste.messages_export_v2.plist"

ICLOUD_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
DATA_DIR="$ICLOUD_ROOT/Documents/Social/Messaging/iMessage"

SCRIPTABLE_DIR="$HOME/Library/Mobile Documents/iCloud~dk~simonbs~Scriptable/Documents/imessages"
TEMPLATES_DIR="$SCRIPTABLE_DIR/templates"
AVATARS_DIR="$SCRIPTABLE_DIR/avatars"

DESKTOP_SHORTCUT="$HOME/Desktop/iMessage Exporter.command"

# Default Python candidates (you can change this list)
PY_CANDIDATES=(
  "/opt/homebrew/bin/python3"
  "/usr/local/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.*/bin/python3"
  "/usr/bin/python3"
)

# ────────────────────────────────────────────────────────────────────────────
# UI helpers
# ────────────────────────────────────────────────────────────────────────────
autoload -Uz is-at-least 2>/dev/null || true
EM_OK="✅"; EM_FAIL="❌"; EM_STEP="•"

# Print a left-justified step and then append status later
function step_start() {
  local msg="$1"
  printf "%s %s " "$EM_STEP" "$msg"
}

function step_ok()   { echo "[OK]";   }
function step_fail() { echo "[FAIL: $1]"; }

# Run a command; on error show brief reason & return non-zero (don’t exit)
function run_or_report() {
  local cmd="$1"
  eval "$cmd" 2> /tmp/imexp.err
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    local reason="$(tr -d '\n' < /tmp/imexp.err | sed 's/^ *//;s/ *$//' )"
    [[ -z "$reason" ]] && reason="error $rc"
    step_fail "$reason"
    return $rc
  fi
  step_ok
  return 0
}

# Prompt with default
function ask() {
  local prompt="$1"; local def="$2"
  v=""
  read "v?$prompt [$def]: "
  echo "${v:-$def}"
}

# ────────────────────────────────────────────────────────────────────────────
# Download + verify helpers
# ────────────────────────────────────────────────────────────────────────────
function gh_url() {
  local file="$1"
  echo "https://github.com/${GH_OWNER}/${GH_REPO}/releases/download/${RELEASE_TAG}/${file}"
}

function download_asset() {
  local file="$1" dest="$2"
  curl -fsSL --retry 3 --retry-delay 1 "$(gh_url "$file")" -o "$dest"
}

function verify_checksum() {
  local file="$1" expected="$2"
  [[ -z "$expected" ]] && return 0  # skip if not provided
  if command -v shasum >/dev/null 2>&1; then
    local got="$(shasum -a 256 "$file" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    local got="$(sha256sum "$file" | awk '{print $1}')"
  else
    echo "  (checksum tools not found; skipping verify)"
    return 0
  fi
  if [[ "$got" == "$expected" ]]; then
    return 0
  else
    echo "  expected: $expected"
    echo "  got:      $got"
    return 1
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Python selection
# ────────────────────────────────────────────────────────────────────────────
function select_python() {
  local found=()
  for pat in "${PY_CANDIDATES[@]}"; do
    for p in ${(f)"$(ls -1d $pat 2>/dev/null || true)"}; do
      [[ -x "$p" ]] && found+=("$p")
    done
  done
  # Include PATH python3 (if different)
  local w="$(command -v python3 2>/dev/null || true)"
  if [[ -n "$w" ]] && [[ ! " ${found[*]} " == *" $w "* ]]; then
    found+=("$w")
  fi

  # Deduplicate
  typeset -A uniq; local list=()
  for p in "${found[@]}"; do
    [[ -z "$p" ]] && continue
    uniq["$p"]=1
  done
  for k in "${(@k)uniq}"; do list+=("$k"); done

  if (( ${#list[@]} == 0 )); then
    echo "/usr/bin/python3"; return
  fi

  echo ""
  echo "Available python3 interpreters:"
  local i=1
  for p in "${list[@]}"; do
    echo "  $i) $p"
    ((i++))
  done
  local choice
  read "choice?Select one (1-${#list[@]}) [1]: "
  choice="${choice:-1}"
  if ! [[ "$choice" =~ '^[0-9]+$' ]] || (( choice < 1 || choice > ${#list[@]} )); then
    choice=1
  fi
  echo "${list[$choice]}"
}

# ────────────────────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────────────────────
clear
cat <<'BANNER'
=====================================================
  iMessage Exporter (imexporter) — Installer
=====================================================
This will:
 • Create app & data folders (macOS + iCloud)
 • Let you choose a Python interpreter
 • Download the CLI and Scriptable templates from GitHub
 • Write a LaunchAgent (disabled by default—you can enable in the app)
 • Print next steps incl. Full Disk Access guidance
BANNER
echo ""

# 1) Preflight: required tools
step_start "Preflight: curl availability"
if command -v curl >/dev/null 2>&1; then step_ok; else step_fail "curl not found"; exit 1; fi

step_start "Preflight: iCloud Drive path"
if [[ -d "$ICLOUD_ROOT" ]]; then step_ok; else step_fail "iCloud Drive not detected (open Finder → iCloud Drive once)"; fi

# 2) Create directories
step_start "Create app dir"
run_or_report "mkdir -p \"$APP_DIR\""

step_start "Create log dir"
run_or_report "mkdir -p \"$LOG_DIR\""

step_start "Create iCloud data dir"
run_or_report "mkdir -p \"$DATA_DIR\""

step_start "Create Scriptable templates dir"
run_or_report "mkdir -p \"$TEMPLATES_DIR\""

step_start "Create Scriptable avatars dir"
run_or_report "mkdir -p \"$AVATARS_DIR\""

# 3) Choose python
PY_PATH="$(select_python)"
step_start "Selected python: $PY_PATH"
step_ok

# 4) Download assets
echo ""
step_start "Download CLI (imexporter.py)"
if download_asset "imexporter.py" "$APP_PY"; then
  if verify_checksum "$APP_PY" "${SHA256[imexporter.py]}"; then step_ok
  else step_fail "checksum mismatch (CLI)"; fi
else
  step_fail "download failed (CLI)"
fi

for f in imessage_today.js imessage_trend.js imessage_stats.js; do
  step_start "Download Scriptable: $f"
  if download_asset "$f" "$TEMPLATES_DIR/$f"; then
    if verify_checksum "$TEMPLATES_DIR/$f" "${SHA256[$f]}"; then step_ok
    else step_fail "checksum mismatch ($f)"; fi
  else
    step_fail "download failed ($f)"
  fi
done

# 5) Runner + desktop shortcut
step_start "Write runner script"
if cat > "$RUNNER" <<EOF
#!/bin/zsh
export PYTHONUNBUFFERED=1
exec "$PY_PATH" "$APP_PY" "\$@"
EOF
then chmod +x "$RUNNER"; step_ok
else step_fail "could not write runner"; fi

step_start "Write desktop shortcut"
if cat > "$DESKTOP_SHORTCUT" <<EOF
#!/bin/zsh
cd "$APP_DIR"
exec "$PY_PATH" "$APP_PY"
EOF
then chmod +x "$DESKTOP_SHORTCUT"; step_ok
else step_fail "could not write shortcut"; fi

# 6) LaunchAgent (created but not loaded; the app will manage it)
step_start "Write LaunchAgent plist"
if cat > "$LAUNCH_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key> <string>com.ste.messages_export_v2</string>
  <key>StartInterval</key> <integer>1800</integer>
  <key>ProgramArguments</key>
  <array>
    <string>$PY_PATH</string>
    <string>$APP_PY</string>
    <string>--auto-run</string>
  </array>
  <key>StandardOutPath</key> <string>$LOG_OUT</string>
  <key>StandardErrorPath</key> <string>$LOG_ERR</string>
  <key>KeepAlive</key> <true/>
</dict>
</plist>
EOF
then step_ok
else step_fail "could not write plist"; fi

# 7) Summary + next steps
echo ""
echo "====================================================="
echo " Installation Summary"
echo "====================================================="
printf "%-16s %s\n" "Python:" "$PY_PATH"
printf "%-16s %s\n" "CLI:" "$APP_PY"
printf "%-16s %s\n" "Runner:" "$RUNNER"
printf "%-16s %s\n" "Shortcut:" "$DESKTOP_SHORTCUT"
printf "%-16s %s\n" "LaunchAgent:" "$LAUNCH_PLIST"
printf "%-16s %s\n" "Logs:" "$LOG_OUT , $LOG_ERR"
printf "%-16s %s\n" "Data dir:" "$DATA_DIR"
printf "%-16s %s\n" "Templates:" "$TEMPLATES_DIR"
printf "%-16s %s\n" "Avatars:" "$AVATARS_DIR"
echo ""

cat <<'NEXT'
Next steps:
  1) Grant Full Disk Access in System Settings → Privacy & Security:
       • Your Terminal
       • /bin/zsh
       • The Python you selected above
  2) Double-click the desktop shortcut “iMessage Exporter” to launch the app.
  3) In the app, add your first contact and choose Import scope (All / N days / None).
  4) In iOS Scriptable:
       • Open once to sync files
       • Create a File Bookmark named “MessagesStats” → point to iCloud/Documents/Social/Messaging/iMessage
       • Add widgets using the templates (set widget parameter to the contact folder, e.g. +447962786922)
  5) Use the app’s Settings → “Change run frequency” to enable/maintain the LaunchAgent.

Tip: checksum verification is currently optional. Once you publish a release,
     fill in the SHA256[...] values above for strong integrity checks.
NEXT

echo ""
echo "Done."
