#!/bin/zsh
# install_imexporter.sh — “middle-ground” installer (raw tag URLs, self-pinned)
# MIT © Stephen Curtis

# ────────────────────────────────────────────────────────────────────────────
# REPO + VERSION (self-pinned by default)
# Bump VERSION when you cut a new release and re-upload this installer.
# You can also override at runtime with --latest or --tag vX.Y.Z
# ────────────────────────────────────────────────────────────────────────────
GH_OWNER="spcurtis81"
GH_REPO="imexporter"
VERSION="v1.0.1"          # <- bump this per release (self-pinned default)

# ────────────────────────────────────────────────────────────────────────────
# Files to fetch from the tag (paths inside the repo)
# ────────────────────────────────────────────────────────────────────────────
ASSETS=(
  "imexporter.py"                               # -> app dir
  "scriptable/imessage_today.js"                # -> templates dir
  "scriptable/imessage_trend.js"                # -> templates dir
  "scriptable/imessage_stats.js"                # -> templates dir
)

# Optional checksums file (JSON) at the tag root:
# {
#   "imexporter.py": "sha256hex...",
#   "scriptable/imessage_today.js": "sha256hex...",
#   ...
# }
CHECKSUMS_JSON="checksums.json"

# ────────────────────────────────────────────────────────────────────────────
# Target paths (macOS)
# ────────────────────────────────────────────────────────────────────────────
APP_DIR="$HOME/Library/Application Support/messages_export_v2"
APP_PY="$APP_DIR/imexporter.py"
RUNNER="$APP_DIR/run_imexporter.sh"

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

# Default Python candidates
PY_CANDIDATES=(
  "/opt/homebrew/bin/python3"
  "/usr/local/bin/python3"
  "/Library/Frameworks/Python.framework/Versions/3.*/bin/python3"
  "/usr/bin/python3"
)

# ────────────────────────────────────────────────────────────────────────────
# CLI args: --latest  |  --tag vX.Y.Z
# ────────────────────────────────────────────────────────────────────────────
USE_TAG="$VERSION"
for arg in "$@"; do
  case "$arg" in
    --latest) USE_TAG="";;     # resolve via API
    --tag)
      echo "Use --tag with a value, e.g. --tag v1.2.3"
      exit 2
      ;;
    --tag=*)
      USE_TAG="${arg#--tag=}"
      ;;
  esac
done

# ────────────────────────────────────────────────────────────────────────────
# UI helpers
# ────────────────────────────────────────────────────────────────────────────
EM_OK="✅"; EM_FAIL="❌"; EM_STEP="•"

step_start() { printf "%s %s " "$EM_STEP" "$1"; }
step_ok()    { echo "[OK]"; }
step_fail()  { echo "[FAIL: $1]"; }
ask() {
  local prompt="$1"; local def="$2"; local v=""
  read "v?$prompt [$def]: "; echo "${v:-$def}"
}

run_or_report() {
  local cmd="$1"
  eval "$cmd" 2> /tmp/imexp.err
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    local reason="$(tr -d '\n' < /tmp/imexp.err | sed 's/^ *//;s/ *$//' )"
    [[ -z "$reason" ]] && reason="error $rc"
    step_fail "$reason"
    return $rc
  fi
  step_ok; return 0
}

raw_url() {
  local path="$1"
  echo "https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/${USE_TAG}/${path}"
}

latest_tag() {
  # Fast path (no jq dependency): grep the first "tag_name"
  local api="https://api.github.com/repos/${GH_OWNER}/${GH_REPO}/releases/latest"
  local tag=$(curl -fsSL "$api" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  echo "$tag"
}

download() {
  local url="$1" dest="$2"
  curl -fsSL --retry 3 --retry-delay 1 "$url" -o "$dest"
}

calc_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo ""
  fi
}

# ────────────────────────────────────────────────────────────────────────────
# Python selector
# ────────────────────────────────────────────────────────────────────────────
select_python() {
  local found=()
  for pat in "${PY_CANDIDATES[@]}"; do
    for p in ${(f)"$(ls -1d $pat 2>/dev/null || true)"}; do
      [[ -x "$p" ]] && found+=("$p")
    done
  done
  local w="$(command -v python3 2>/dev/null || true)"
  [[ -n "$w" && " ${found[*]} " != *" $w "* ]] && found+=("$w")

  typeset -A uniq; local list=()
  for p in "${found[@]}"; do [[ -n "$p" ]] && uniq["$p"]=1; done
  for k in "${(@k)uniq}"; do list+=("$k"); done

  if (( ${#list[@]} == 0 )); then echo "/usr/bin/python3"; return; fi

  echo ""
  echo "Available python3 interpreters:"
  local i=1; for p in "${list[@]}"; do echo "  $i) $p"; ((i++)); done
  local choice; read "choice?Select one (1-${#list[@]}) [1]: "; choice="${choice:-1}"
  if ! [[ "$choice" =~ '^[0-9]+$' ]] || (( choice < 1 || choice > ${#list[@]} )); then choice=1; fi
  echo "${list[$choice]}"
}

# ────────────────────────────────────────────────────────────────────────────
# Banner
# ────────────────────────────────────────────────────────────────────────────
clear
cat <<'BANNER'
=====================================================
  iMessage Exporter (imexporter) — Installer
=====================================================
This will:
 • Create app & data folders (macOS + iCloud)
 • Let you choose a Python interpreter
 • Download the CLI and Scriptable templates from GitHub (pinned tag)
 • Write a LaunchAgent (disabled by default—manage from the app)
 • Print next steps incl. Full Disk Access guidance
BANNER
echo ""

# Resolve tag
if [[ -z "$USE_TAG" ]]; then
  step_start "Resolving latest release tag"
  tag="$(latest_tag)"
  if [[ -n "$tag" ]]; then USE_TAG="$tag"; step_ok
  else step_fail "could not resolve latest tag"; exit 1; fi
else
  step_start "Using pinned tag"; echo "$USE_TAG [OK]"
fi

# Preflight
step_start "Preflight: curl"
command -v curl >/dev/null 2>&1 && step_ok || { step_fail "curl not found"; exit 1; }

step_start "Preflight: iCloud path"
[[ -d "$ICLOUD_ROOT" ]] && step_ok || step_fail "Open Finder → iCloud Drive once (path not found)"

# Create dirs
step_start "Create app dir";       run_or_report "mkdir -p \"$APP_DIR\""
step_start "Create log dir";       run_or_report "mkdir -p \"$LOG_DIR\""
step_start "Create iCloud data";   run_or_report "mkdir -p \"$DATA_DIR\""
step_start "Create templates dir"; run_or_report "mkdir -p \"$TEMPLATES_DIR\""
step_start "Create avatars dir";   run_or_report "mkdir -p \"$AVATARS_DIR\""

# Choose python
PY_PATH="$(select_python)"
step_start "Selected python: $PY_PATH"; step_ok

# Fetch checksums.json (optional)
CHECKSUMS=""
step_start "Fetch checksums.json (optional)"
cs_url="$(raw_url "$CHECKSUMS_JSON")"
if CHECKSUMS="$(curl -fsSL "$cs_url" 2>/dev/null)"; then
  step_ok
else
  step_fail "not found (skipping verification)"
fi

# Download assets
for path in "${ASSETS[@]}"; do
  fname="${path##*/}"
  if [[ "$path" == scriptable/* ]]; then
    dest="$TEMPLATES_DIR/$fname"
  else
    dest="$APP_DIR/$fname"
  fi
  step_start "Download $path"
  if download "$(raw_url "$path")" "$dest"; then
    # verify if we have checksum for this path
    if [[ -n "$CHECKSUMS" ]]; then
      expected="$(echo "$CHECKSUMS" | /usr/bin/python3 - <<'PY' "$path"
import sys, json
obj=json.loads(sys.stdin.read())
key=sys.argv[1]
print(obj.get(key,""))
PY
)"
      if [[ -n "$expected" ]]; then
        got="$(calc_sha256 "$dest")"
        if [[ -n "$got" && "$got" == "$expected" ]]; then
          step_ok
        else
          step_fail "checksum mismatch"
        fi
      else
        step_ok
      fi
    else
      step_ok
    fi
  else
    step_fail "download failed"
  fi
done

# Runner & desktop shortcut
step_start "Write runner"
if cat > "$RUNNER" <<EOF
#!/bin/zsh
export PYTHONUNBUFFERED=1
exec "$PY_PATH" "$APP_DIR/imexporter.py" "\$@"
EOF
then chmod +x "$RUNNER"; step_ok
else step_fail "runner write failed"; fi

step_start "Write desktop shortcut"
if cat > "$DESKTOP_SHORTCUT" <<EOF
#!/bin/zsh
cd "$APP_DIR"
exec "$PY_PATH" "$APP_DIR/imexporter.py"
EOF
then chmod +x "$DESKTOP_SHORTCUT"; step_ok
else step_fail "shortcut write failed"; fi

# LaunchAgent (created but not loaded; managed in app)
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
    <string>$APP_DIR/imexporter.py</string>
    <string>--auto-run</string>
  </array>
  <key>StandardOutPath</key> <string>$LOG_OUT</string>
  <key>StandardErrorPath</key> <string>$LOG_ERR</string>
  <key>KeepAlive</key> <true/>
</dict>
</plist>
EOF
then step_ok
else step_fail "plist write failed"; fi

# Summary
echo ""
echo "====================================================="
echo " Installation Summary"
echo "====================================================="
printf "%-16s %s\n" "Tag:" "$USE_TAG"
printf "%-16s %s\n" "Python:" "$PY_PATH"
printf "%-16s %s\n" "CLI:" "$APP_DIR/imexporter.py"
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
  2) Double-click “iMessage Exporter.command” on your Desktop to open the app.
  3) In the app, add your first contact and choose import scope (All / N days / None).
  4) On iOS:
       • Open Scriptable once to sync
       • Create a File Bookmark named “MessagesStats” → iCloud/Documents/Social/Messaging/iMessage
       • Add widgets using the templates
  5) Use the app’s Settings → “Change run frequency” to enable the LaunchAgent.
Tip: If you publish checksums.json at each tag, the installer will auto-verify.
     Otherwise, it skips verification and still installs.
NEXT

echo ""
echo "Done."
