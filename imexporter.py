#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
imexporter.py — iMessage Exporter (DM-only)
MIT © Stephen Curtis

What this app does
------------------
• Exports iMessage DM history for selected contacts from the local Messages DB.
• Writes per-contact files in iCloud so Scriptable widgets / dashboards can consume them.
• Appends only NEW rows using a simple state file (no duplicates).
• Builds per-day rollups: days[YYYY-MM-DD] => { me, them, total }.
• Provides a simple CLI menu for: Run Export, Add New Number, Settings, Help.
• Manages a LaunchAgent (interval) to auto-run every N minutes.
• Records last run timestamps and prints clear progress lines.

Important
---------
• The *first run* for a contact can import “All available” *on your Mac right now*.
  If iCloud later downloads older history, subsequent runs will include it too.
• You must grant **Full Disk Access** to:
    - your chosen python3 interpreter
    - your Terminal app
    - /bin/zsh
  (System Settings → Privacy & Security → Full Disk Access)
"""

import os, sys, json, csv, sqlite3, textwrap, shutil, subprocess, time
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Constants / Paths
# ─────────────────────────────────────────────────────────────────────────────
HOME = Path.home()

# App config + logs live locally (not in iCloud)
APP_DIR = HOME / "Library" / "Application Support" / "imexporter"
LOG_DIR = HOME / "Library" / "Logs"
OUT_LOG = LOG_DIR / "imexporter.out"
ERR_LOG = LOG_DIR / "imexporter.err"

# Data lives in iCloud (unchanged – this is where your JSON lives now)
ICLOUD_ROOT = HOME / "Library" / "Mobile Documents" / "com~apple~CloudDocs"
DATA_ROOT = ICLOUD_ROOT / "Documents" / "Social" / "Messaging" / "iMessage"

INDEX_JSON = DATA_ROOT / "index.json"
ME_AVATAR = DATA_ROOT / "_me" / "avatar.png"

CONFIG_JSON = APP_DIR / "config.json"
LAUNCH_PLIST = HOME / "Library" / "LaunchAgents" / "com.ste.imexporter.plist"

SCRIPT_PATH = Path(__file__).resolve()
PY_DEFAULT = shutil.which("python3") or "/usr/bin/python3"

# Messages DB — this may differ on older macOS, but this works on Sonoma+.
DB_PATHS = [
    HOME / "Library" / "Messages" / "chat.db",
]

# ─────────────────────────────────────────────────────────────────────────────
# CLI Banner
# ─────────────────────────────────────────────────────────────────────────────
def banner():
    year = datetime.now().year
    print("="*59)
    print(" iMessage Exporter (imexporter)".center(59))
    print("="*59)
    print(f"MIT © Stephen Curtis, {year}")
    print()

# ─────────────────────────────────────────────────────────────────────────────
# Utilities
# ─────────────────────────────────────────────────────────────────────────────
def ensure_dirs():
    (APP_DIR).mkdir(parents=True, exist_ok=True)
    (LOG_DIR).mkdir(parents=True, exist_ok=True)
    (DATA_ROOT).mkdir(parents=True, exist_ok=True)
    (DATA_ROOT / "_me").mkdir(parents=True, exist_ok=True)

def load_config():
    cfg = {
        "python_path": PY_DEFAULT,
        "refresh_minutes": 30,
    }
    if CONFIG_JSON.exists():
        try:
            cfg.update(json.loads(CONFIG_JSON.read_text()))
        except Exception:
            pass
    return cfg

def save_config(cfg):
    CONFIG_JSON.write_text(json.dumps(cfg, indent=2))

def print_ok(msg):   print(f"✅ {msg}")
def print_fail(msg): print(f"❌ {msg}")
def print_info(msg): print(f"•  {msg}")

def iso_now():
    return datetime.now().astimezone().replace(microsecond=0).isoformat()

def apple_time_to_iso(apple_time):
    """
    Messages 'date' is Apple Absolute Time.
    Newer macOS: nanoseconds since 2001-01-01.
    Older: seconds since 2001-01-01.
    We auto-detect by magnitude.
    """
    if apple_time is None:
        return None
    try:
        t = int(apple_time)
    except Exception:
        return None

    base = datetime(2001,1,1, tzinfo=timezone.utc)
    # Heuristic
    if abs(t) > 1_000_000_000_000:  # > ~2001s in ns
        dt = base + timedelta(seconds=t/1_000_000_000)
    else:
        dt = base + timedelta(seconds=t)
    return dt.astimezone().replace(microsecond=0).isoformat()

def day_key_from_iso(iso):
    # iso: "YYYY-MM-DDTHH:MM:SS+ZZ:ZZ"
    return (iso or "")[:10] if iso else None

def human_bytes(n):
    for unit in ["B","KB","MB","GB","TB"]:
        if n < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"

# ─────────────────────────────────────────────────────────────────────────────
# Messages DB helpers
# ─────────────────────────────────────────────────────────────────────────────
def find_messages_db():
    for p in DB_PATHS:
        if p.exists():
            return p
    return None

def open_db():
    db_path = find_messages_db()
    if not db_path:
        raise FileNotFoundError("Messages chat.db not found. Check Full Disk Access.")
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn

def fetch_handle_ids_for_number(conn, number):
    # Messages normalises phone numbers; we try both raw and E.164-ish
    like_number = number.replace(" ", "")
    cur = conn.cursor()
    cur.execute(
        """
        SELECT ROWID, id
        FROM handle
        WHERE id LIKE ? OR id LIKE ?
        """,
        (f"%{like_number}", f"%{like_number.replace('+','')}"),
    )
    rows = cur.fetchall()
    return [r["ROWID"] for r in rows]

def fetch_messages_for_handles(conn, handle_ids, since_rowid=None):
    if not handle_ids:
        return []

    params = list(handle_ids)
    handle_clause = ",".join("?" for _ in handle_ids)

    where = f"m.handle_id IN ({handle_clause})"
    if since_rowid is not None:
        where += " AND m.ROWID > ?"
        params.append(since_rowid)

    sql = f"""
    SELECT
        m.ROWID as rowid,
        m.date as date,
        m.is_from_me as is_from_me,
        m.text as text
    FROM message m
    WHERE {where}
    ORDER BY m.ROWID ASC
    """
    cur = conn.cursor()
    cur.execute(sql, params)
    return cur.fetchall()

# ─────────────────────────────────────────────────────────────────────────────
# Index / Contacts
# ─────────────────────────────────────────────────────────────────────────────
def load_index():
    """
    index.json lives in the iCloud data root and describes:
    {
      "contacts": [
        {
          "number": "+44....",
          "label": "Friendly Name",
          "enabled": true
        },
        ...
      ]
    }
    """
    if not INDEX_JSON.exists():
        return {"contacts": []}
    try:
        return json.loads(INDEX_JSON.read_text())
    except Exception:
        return {"contacts": []}

def save_index(idx):
    DATA_ROOT.mkdir(parents=True, exist_ok=True)
    INDEX_JSON.write_text(json.dumps(idx, indent=2, ensure_ascii=False))

def list_contacts():
    idx = load_index()
    return idx.get("contacts", [])

def add_contact(number: str, label: str):
    idx = load_index()
    contacts = idx.get("contacts", [])
    for c in contacts:
        if c.get("number") == number:
            c["label"] = label
            c["enabled"] = True
            break
    else:
        contacts.append({"number": number, "label": label, "enabled": True})
    idx["contacts"] = contacts
    save_index(idx)

def disable_contact(number: str):
    idx = load_index()
    changed = False
    for c in idx.get("contacts", []):
        if c.get("number") == number:
            c["enabled"] = False
            changed = True
    if changed:
        save_index(idx)

# ─────────────────────────────────────────────────────────────────────────────
# Per-contact state
# ─────────────────────────────────────────────────────────────────────────────
def contact_dir(number: str) -> Path:
    # Folder name = number exactly (e.g. "+4479...")
    d = DATA_ROOT / number
    d.mkdir(parents=True, exist_ok=True)
    return d

def state_path(number: str) -> Path:
    return contact_dir(number) / "state.json"

def load_state(number: str):
    p = state_path(number)
    if not p.exists():
        return {"last_rowid": None, "last_run": None}
    try:
        return json.loads(p.read_text())
    except Exception:
        return {"last_rowid": None, "last_run": None}

def save_state(number: str, state: dict):
    p = state_path(number)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(p)

# ─────────────────────────────────────────────────────────────────────────────
# Export + rollup
# ─────────────────────────────────────────────────────────────────────────────
def export_for_contact(conn, number: str, label: str):
    handles = fetch_handle_ids_for_number(conn, number)
    if not handles:
        print_fail(f"{number}: no matching handles in Messages DB")
        return

    st = load_state(number)
    last_rowid = st.get("last_rowid")

    rows = fetch_messages_for_handles(conn, handles, since_rowid=last_rowid)
    if not rows and last_rowid is not None:
        # Nothing new, nothing to do
        print_info(f"{number} ({label}): no new messages")
        st["last_run"] = iso_now()
        save_state(number, st)
        return

    # If first run (last_rowid is None), we export all rows
    if not rows and last_rowid is None:
        print_info(f"{number} ({label}): no messages found at all")
        st["last_run"] = iso_now()
        save_state(number, st)
        return

    # Build full data structure by merging existing + new
    cdir = contact_dir(number)
    json_path = cdir / f"messages_{number}_dm.json"
    csv_path = cdir / f"messages_{number}_dm.csv"
    rollup_path = cdir / "rollup.json"

    existing = []
    if json_path.exists():
        try:
            existing = json.loads(json_path.read_text())
        except Exception:
            existing = []

    # Convert DB rows to JSON records
    new_records = []
    max_rowid = last_rowid or 0
    for r in rows:
        rowid = r["rowid"]
        if rowid > max_rowid:
            max_rowid = rowid
        iso_ts = apple_time_to_iso(r["date"])
        new_records.append({
            "rowid": rowid,
            "date": iso_ts,
            "is_from_me": bool(r["is_from_me"]),
            "text": r["text"],
        })

    merged = existing + new_records

    # Atomic write JSON
    tmp = json_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(merged, indent=2, ensure_ascii=False))
    tmp.replace(json_path)

    # CSV write
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["rowid", "date", "is_from_me", "text"])
        for msg in merged:
            w.writerow([
                msg["rowid"],
                msg["date"],
                1 if msg["is_from_me"] else 0,
                msg["text"] or "",
            ])

    # Build per-day rollups
    days = {}
    for msg in merged:
        dk = day_key_from_iso(msg["date"])
        if not dk:
            continue
        bucket = days.setdefault(dk, {"me": 0, "them": 0, "total": 0})
        bucket["total"] += 1
        if msg["is_from_me"]:
            bucket["me"] += 1
        else:
            bucket["them"] += 1

    tmp_r = rollup_path.with_suffix(".tmp")
    tmp_r.write_text(json.dumps({"days": days}, indent=2, ensure_ascii=False))
    tmp_r.replace(rollup_path)

    st["last_rowid"] = max_rowid
    st["last_run"] = iso_now()
    save_state(number, st)

    print_ok(f"{number} ({label}): exported {len(new_records)} new messages (total {len(merged)})")

# ─────────────────────────────────────────────────────────────────────────────
# Logging redirection for CLI vs LaunchAgent
# ─────────────────────────────────────────────────────────────────────────────
def redirect_logs_if_needed():
    """
    When run as LaunchAgent (auto-run), stdout/stderr are already redirected
    by run_imexporter.sh, so we just use normal prints.

    When run from Terminal, we want to write logs both to console and to the
    log files; for simplicity we keep prints to console and rely on the shell
    redirect for the agent.
    """
    # Nothing special here for now; kept for future extension.
    ensure_dirs()

# ─────────────────────────────────────────────────────────────────────────────
# CLI menus
# ─────────────────────────────────────────────────────────────────────────────
def choose_contact_interactively():
    contacts = list_contacts()
    enabled = [c for c in contacts if c.get("enabled", True)]
    if not enabled:
        print("No contacts configured yet.")
        return None

    print()
    print("Select contact:")
    for i, c in enumerate(enabled, start=1):
        print(f"{i}) {c['label']} ({c['number']})")
    print("0) Cancel")
    try:
        choice = int(input("> ").strip() or "0")
    except ValueError:
        return None
    if choice <= 0 or choice > len(enabled):
        return None
    return enabled[choice-1]

def add_contact_menu():
    print()
    print("Add / Enable Contact")
    print("--------------------")
    number = input("Enter phone number (E.164, e.g. +4479...): ").strip()
    if not number:
        print("Cancelled.")
        return
    label = input("Display name: ").strip() or number
    add_contact(number, label)
    print_ok(f"Saved contact {label} ({number})")

def list_contacts_menu():
    contacts = list_contacts()
    if not contacts:
        print("No contacts configured.")
        return
    print()
    print("Configured contacts:")
    print("--------------------")
    for c in contacts:
        flag = "✅" if c.get("enabled", True) else "❌"
        print(f"{flag} {c['label']} ({c['number']})")

# ─────────────────────────────────────────────────────────────────────────────
# LaunchAgent template & management
# ─────────────────────────────────────────────────────────────────────────────
PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key> <string>com.ste.imexporter</string>
  <key>StartInterval</key> <integer>{interval}</integer>
  <key>ProgramArguments</key>
  <array>
    <string>{python}</string>
    <string>{script}</string>
    <string>--auto-run</string>
  </array>
  <key>StandardOutPath</key> <string>{outlog}</string>
  <key>StandardErrorPath</key> <string>{errlog}</string>
  <key>KeepAlive</key> <true/>
</dict>
</plist>
"""

def write_launch_agent(refresh_minutes: int, python_path: str):
    payload = PLIST_TEMPLATE.format(
        interval=max(60, int(refresh_minutes)*60),
        python=python_path,
        script=str(SCRIPT_PATH),
        outlog=str(OUT_LOG),
        errlog=str(ERR_LOG),
    )
    LAUNCH_PLIST.write_text(payload)
    print_ok(f"Wrote LaunchAgent plist with interval={refresh_minutes} min")
    print_info(f"{LAUNCH_PLIST}")

def reload_launch_agent():
    label = "com.ste.imexporter"
    # Try unload then load (ignore errors)
    subprocess.run(
        ["launchctl", "bootout", f"gui/{os.getuid()}/{LAUNCH_PLIST}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["launchctl", "bootstrap", f"gui/{os.getuid()}", str(LAUNCH_PLIST)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{label}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print_ok("Reloaded LaunchAgent")

# ─────────────────────────────────────────────────────────────────────────────
# Settings menu
# ─────────────────────────────────────────────────────────────────────────────
def settings_menu():
    cfg = load_config()
    while True:
        print()
        print("Settings")
        print("--------")
        print("1) Change run frequency (minutes)")
        print("2) Scan/select Python interpreter")
        print("3) Config Summary")
        print("0) Back")
        choice = input("> ").strip()
        if choice == "1":
            try:
                mins = int(input("Minutes between runs (min 1): ").strip())
            except ValueError:
                print_fail("Invalid number")
                continue
            if mins < 1:
                mins = 1
            cfg["refresh_minutes"] = mins
            save_config(cfg)
            write_launch_agent(cfg["refresh_minutes"], cfg["python_path"])
            reload_launch_agent()
        elif choice == "2":
            pick_python_menu(cfg)
        elif choice == "3":
            print()
            print("Current config:")
            print(json.dumps(cfg, indent=2))
            print(f"App dir: {APP_DIR}")
            print(f"Data root: {DATA_ROOT}")
        elif choice == "0":
            return
        else:
            print("Unknown option.")

def scan_pythons():
    candidates = []
    # Common locations
    for p in [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]:
        if Path(p).exists():
            candidates.append(p)
    # Also scan PATH
    which = shutil.which("python3")
    if which and which not in candidates:
        candidates.append(which)
    return candidates

def pick_python_menu(cfg):
    cands = scan_pythons()
    if not cands:
        print_fail("No python3 interpreters found. Install Python first.")
        return
    print()
    print("Select python3 interpreter:")
    for i, p in enumerate(cands, start=1):
        print(f"{i}) {p}")
    print("0) Cancel")
    try:
        choice = int(input("> ").strip() or "0")
    except ValueError:
        return
    if choice <= 0 or choice > len(cands):
        return
    chosen = cands[choice-1]
    cfg["python_path"] = chosen
    save_config(cfg)
    write_launch_agent(cfg["refresh_minutes"], cfg["python_path"])
    reload_launch_agent()

# ─────────────────────────────────────────────────────────────────────────────
# Main export runner
# ─────────────────────────────────────────────────────────────────────────────
def run_export(auto: bool = False):
    ensure_dirs()
    idx = load_index()
    contacts = [c for c in idx.get("contacts", []) if c.get("enabled", True)]
    if not contacts:
        print_info("No enabled contacts found in index.json. Nothing to export.")
        return

    conn = open_db()
    try:
        total_new = 0
        for c in contacts:
            number = c.get("number")
            label = c.get("label", number)
            before_state = load_state(number)
            before_rowid = before_state.get("last_rowid")
            export_for_contact(conn, number, label)
            after_state = load_state(number)
            if after_state.get("last_rowid") and after_state.get("last_rowid") != before_rowid:
                total_new += 1
        print_info(f"Checked at {iso_now()}: {total_new} contacts had new messages")
    finally:
        conn.close()

# ─────────────────────────────────────────────────────────────────────────────
# Top-level CLI
# ─────────────────────────────────────────────────────────────────────────────
def main(argv=None):
    argv = argv or sys.argv[1:]
    ensure_dirs()
    banner()

    if "--auto-run" in argv:
        # Launched by LaunchAgent
        run_export(auto=True)
        return 0

    while True:
        print("Main Menu")
        print("---------")
        print("1) Run Export Now")
        print("2) Add / Enable Contact")
        print("3) List Contacts")
        print("4) Settings")
        print("5) Help")
        print("0) Quit")
        choice = input("> ").strip()
        if choice == "1":
            run_export(auto=False)
        elif choice == "2":
            add_contact_menu()
        elif choice == "3":
            list_contacts_menu()
        elif choice == "4":
            settings_menu()
        elif choice == "5":
            print()
            print("Help")
            print("----")
            print(textwrap.dedent("""
                • Add contacts using option 2 (E.164 format, e.g. +4479...).
                • Data is written under iCloud Drive:
                    Documents/Social/Messaging/iMessage/
                • Each contact gets:
                    messages_<number>_dm.json
                    messages_<number>_dm.csv
                    rollup.json
                    state.json
                • Use Settings to choose Python and auto-run interval.
                """).strip())
        elif choice == "0":
            return 0
        else:
            print("Unknown option.")

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        print("Interrupted by user.")
        sys.exit(1)